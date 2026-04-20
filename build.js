import {readFileSync, writeFileSync, appendFileSync} from "node:fs";
import {mergeCidr, overlapCidr, excludeCidr} from "cidr-tools";

const POLICY_FILE = "policy.hujson";
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

    const connectors =
        policy.nodeAttrs[0].app["tailscale.com/app-connectors"];

    // Load and merge CIDRs for each segment (mergeCidr returns sorted results)
    const loaded = {};
    for (const [name, sources] of Object.entries(segments)) {
        loaded[name] = await loadSegment(sources);
        console.log(`${name}: ${loaded[name].length} CIDRs`);
    }

    // Ensure ru and eu CIDR lists don't overlap
    if (overlapCidr(loaded.ru, loaded.eu)) {
        // Find which CIDRs overlap efficiently using bulk excludeCidr (2 calls)
        // instead of per-CIDR overlapCidr which is O(n*m).
        // excludeCidr returns parts of A not covered by B — any original CIDR
        // missing from the result overlaps with the other segment.
        const ruOnlySet = new Set(excludeCidr(loaded.ru, loaded.eu));
        const euOnlySet = new Set(excludeCidr(loaded.eu, loaded.ru));
        const ruOverlaps = loaded.ru.filter((c) => !ruOnlySet.has(c));
        const euOverlaps = loaded.eu.filter((c) => !euOnlySet.has(c));

        const lines = [
            `CIDR conflict: ru and eu segments overlap (${ruOverlaps.length} from ru, ${euOverlaps.length} from eu)`,
            `  ru → eu: ${ruOverlaps.length} CIDRs`,
            ...ruOverlaps.slice(0, 10).map((c) => `    ${c}`),
            ...(ruOverlaps.length > 10 ? [`    … and ${ruOverlaps.length - 10} more`] : []),
            `  eu → ru: ${euOverlaps.length} CIDRs`,
            ...euOverlaps.slice(0, 10).map((c) => `    ${c}`),
            ...(euOverlaps.length > 10 ? [`    … and ${euOverlaps.length - 10} more`] : []),
        ];
        console.error(lines.join("\n"));

        // Write summary to GitHub Actions Job Summary if available
        if (process.env.GITHUB_STEP_SUMMARY) {
            const md = [
                "## ⚠️ CIDR Overlap Detected",
                "",
                `**Overlapping CIDRs:** ${ruOverlaps.length} from ru, ${euOverlaps.length} from eu`,
                "",
                `### ru → eu (${ruOverlaps.length})`,
                ...ruOverlaps.slice(0, 25).map((c) => `- \`${c}\``),
                ...(ruOverlaps.length > 25 ? [`- … and ${ruOverlaps.length - 25} more`] : []),
                "",
                `### eu → ru (${euOverlaps.length})`,
                ...euOverlaps.slice(0, 25).map((c) => `- \`${c}\``),
                ...(euOverlaps.length > 25 ? [`- … and ${euOverlaps.length - 25} more`] : []),
            ];
            appendFileSync(process.env.GITHUB_STEP_SUMMARY, md.join("\n") + "\n");
        }

        throw new Error(`CIDR conflict: ru and eu segments overlap (${ruOverlaps.length} from ru, ${euOverlaps.length} from eu)`);
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
