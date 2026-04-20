import {readFileSync, writeFileSync, appendFileSync} from "node:fs";
import {mergeCidr} from "cidr-tools";

const POLICY_FILE = "policy.hujson";
const OVERRIDES_FILE = "overrides.json";
const FETCH_TIMEOUT_MS = 30_000;

const GEOIP_TEXT_BASE =
    "https://raw.githubusercontent.com/runetfreedom/russia-blocked-geoip/release/text";

const segments = {
    ru: ["ru-whitelist", "yandex"],
    eu: [
        "ru-blocked",
        "ru-blocked-community",
        "re-filter",
        "cloudflare",
        "ddos-guard",
        "facebook",
        "google",
        "netflix",
        "telegram",
        "twitter",
    ],
};

async function downloadFile(name) {
    const url = `${GEOIP_TEXT_BASE}/${name}.txt`;
    console.log(`Downloading: ${url}`);
    const res = await fetch(url, {signal: AbortSignal.timeout(FETCH_TIMEOUT_MS)});
    if (!res.ok) throw new Error(`Failed to download ${url}: ${res.status}`);
    return res.text();
}

function parseCIDRs(text) {
    return text
        .split("\n")
        .map((l) => l.trim())
        .filter((l) => l && !l.startsWith("#"));
}

async function loadSegment(sources) {
    const allCIDRs = [];
    for (const name of sources) {
        const text = await downloadFile(name);
        allCIDRs.push(...parseCIDRs(text));
    }
    return mergeCidr(allCIDRs);
}

async function main() {
    const policy = JSON.parse(readFileSync(POLICY_FILE, "utf-8"));
    const overrides = JSON.parse(readFileSync(OVERRIDES_FILE, "utf-8"));

    const connectors =
        policy.nodeAttrs[0].app["tailscale.com/app-connectors"];

    // Load and merge CIDRs for each segment (mergeCidr returns sorted results)
    const loaded = {};
    for (const [name, sources] of Object.entries(segments)) {
        loaded[name] = await loadSegment(sources);
        console.log(`${name}: ${loaded[name].length} CIDRs`);
    }

    // Find exact-duplicate CIDRs present in both segments
    const ruSet = new Set(loaded.ru);
    const duplicates = loaded.eu.filter((c) => ruSet.has(c));

    if (duplicates.length > 0) {
        // Split duplicates into resolved (present in overrides) and unresolved
        const resolved = [];
        const unresolved = [];
        for (const cidr of duplicates) {
            if (cidr in overrides) {
                resolved.push(cidr);
            } else {
                unresolved.push(cidr);
            }
        }

        // Apply overrides: keep CIDR in the designated segment, remove from the other
        const removeFromRu = new Set();
        const removeFromEu = new Set();
        for (const cidr of resolved) {
            const seg = overrides[cidr];
            if (seg !== "ru" && seg !== "eu") {
                throw new Error(`Invalid segment "${seg}" for ${cidr} in ${OVERRIDES_FILE} (expected "ru" or "eu")`);
            }
            if (seg === "ru") {
                removeFromEu.add(cidr);
            } else {
                removeFromRu.add(cidr);
            }
        }

        // Unresolved duplicates are removed from both segments
        for (const cidr of unresolved) {
            removeFromRu.add(cidr);
            removeFromEu.add(cidr);
        }

        loaded.ru = loaded.ru.filter((c) => !removeFromRu.has(c));
        loaded.eu = loaded.eu.filter((c) => !removeFromEu.has(c));

        // Log resolved overrides
        if (resolved.length > 0) {
            console.log(`Resolved ${resolved.length} duplicate CIDRs via overrides:`);
            for (const cidr of resolved) {
                console.log(`  ${cidr} → ${overrides[cidr]}`);
            }
        }

        // Report unresolved duplicates
        if (unresolved.length > 0) {
            console.warn(
                `Removed ${unresolved.length} unresolved duplicate CIDRs from both segments:`
            );
            for (const cidr of unresolved) {
                console.warn(`  ${cidr}`);
            }

            if (process.env.GITHUB_STEP_SUMMARY) {
                const md = [
                    "## ⚠️ Unresolved CIDR Duplicates",
                    "",
                    `**${unresolved.length}** exact-duplicate CIDRs found in both ru and eu segments were removed from both.`,
                    "Add them to `overrides.json` to assign a preferred segment.",
                    "",
                    ...unresolved.map((c) => `- \`${c}\``),
                ];
                appendFileSync(process.env.GITHUB_STEP_SUMMARY, md.join("\n") + "\n");
            }
        }
    }

    for (const [name, cidrs] of Object.entries(loaded)) {
        const connector = connectors.find((c) => c.name === name);
        if (!connector) throw new Error(`Connector "${name}" not found in ${POLICY_FILE}`);
        connector.routes = cidrs;
    }

    writeFileSync(POLICY_FILE, JSON.stringify(policy, null, 2) + "\n");
    console.log(`${POLICY_FILE}: updated`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
