import {readFileSync, writeFileSync} from "node:fs";
import {mergeCidr} from "cidr-tools";

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

    for (const [name, sources] of Object.entries(segments)) {
        const cidrs = await loadSegment(sources);
        const connector = connectors.find((c) => c.name === name);
        if (!connector) throw new Error(`Connector "${name}" not found in ${POLICY_FILE}`);
        connector.routes = cidrs;
        console.log(`${name}: ${cidrs.length} CIDRs`);
    }

    writeFileSync(POLICY_FILE, JSON.stringify(policy, null, 2) + "\n");
    console.log(`${POLICY_FILE}: updated`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
