import {readFileSync, writeFileSync} from "node:fs";
import {mergeCidr, excludeCidr, parseCidr, containsCidr} from "cidr-tools";
import JSON5 from "json5";

const POLICY_FILE = "policy.hujson";
const FETCH_TIMEOUT_MS = 30_000;

// IPverse RIR aggregated country ranges (source of truth for RU).
const IPVERSE_BASE =
    "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ru";
const RU_IPV4_URL = `${IPVERSE_BASE}/ipv4-aggregated.txt`;
const RU_IPV6_URL = `${IPVERSE_BASE}/ipv6-aggregated.txt`;

// IPv4 base for EU = entire IPv4 internet.
const IPV4_BASE = "0.0.0.0/0";

// IPv6 base for EU = global unicast space; this naturally excludes
// private/ULA, link-local, multicast and other reserved IPv6 blocks.
const IPV6_BASE = "2000::/3";

// IPv4 special-use / technical ranges removed from EU before subtracting RU.
// Note: only 100.64.0.0/10 (CGNAT/Tailscale) is excluded, not the full 100.0.0.0/8.
const IPV4_TECHNICAL = [
    "0.0.0.0/8",         // "this network"
    "10.0.0.0/8",        // private LAN
    "100.64.0.0/10",     // CGNAT / Tailscale shared address space
    "127.0.0.0/8",       // loopback
    "169.254.0.0/16",    // IPv4 link-local
    "172.16.0.0/12",     // private LAN
    "192.0.0.0/24",      // IETF protocol assignments
    "192.0.2.0/24",      // documentation / TEST-NET-1
    "192.88.99.0/24",    // deprecated 6to4 relay anycast
    "192.168.0.0/16",    // private LAN
    "198.18.0.0/15",     // benchmark / testing
    "198.51.100.0/24",   // documentation / TEST-NET-2
    "203.0.113.0/24",    // documentation / TEST-NET-3
    "224.0.0.0/4",       // multicast
    "240.0.0.0/4",       // reserved / future use
];

async function downloadCIDRs(url) {
    console.log(`Downloading: ${url}`);
    const res = await fetch(url, {signal: AbortSignal.timeout(FETCH_TIMEOUT_MS)});
    if (!res.ok) throw new Error(`Failed to download ${url}: ${res.status}`);
    const text = await res.text();
    return text
        .split("\n")
        .map((l) => l.trim())
        .filter((l) => l && !l.startsWith("#"));
}

function isV6(cidr) {
    return cidr.includes(":");
}

function validateRoutes(routes, name) {
    const seen = new Set();
    for (const c of routes) {
        try {
            parseCidr(c);
        } catch {
            throw new Error(`${name}: invalid CIDR ${c}`);
        }
        if (seen.has(c)) throw new Error(`${name}: exact duplicate CIDR ${c}`);
        seen.add(c);
    }
}

// Returns [aCidr, bCidr] for the first overlapping pair (containment or
// equality) between two CIDR lists, or null. Runs per-IP-version in O(n+m)
// using a sorted-merge over parsed [start,end] ranges.
function findCidrOverlap(aList, bList) {
    for (const v of [4, 6]) {
        const a = aList
            .filter((c) => (isV6(c) ? 6 : 4) === v)
            .map((c) => {
                const p = parseCidr(c);
                return [p.start, p.end, c];
            })
            .sort((x, y) => (x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : 0));
        const b = bList
            .filter((c) => (isV6(c) ? 6 : 4) === v)
            .map((c) => {
                const p = parseCidr(c);
                return [p.start, p.end, c];
            })
            .sort((x, y) => (x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : 0));
        let i = 0, j = 0;
        while (i < a.length && j < b.length) {
            if (a[i][1] < b[j][0]) { i++; continue; }
            if (b[j][1] < a[i][0]) { j++; continue; }
            return [a[i][2], b[j][2]];
        }
    }
    return null;
}

async function main() {
    const policy = JSON5.parse(readFileSync(POLICY_FILE, "utf-8"));

    const connectors =
        policy.nodeAttrs[0].app["tailscale.com/app-connectors"];
    const ruConn = connectors.find((c) => c.name === "ru");
    const euConn = connectors.find((c) => c.name === "eu");
    if (!ruConn) throw new Error(`Connector "ru" not found in ${POLICY_FILE}`);
    if (!euConn) throw new Error(`Connector "eu" not found in ${POLICY_FILE}`);

    // ---- RU: IPverse Russia IPv4 + IPv6 ----
    const [ruV4Raw, ruV6Raw] = await Promise.all([
        downloadCIDRs(RU_IPV4_URL),
        downloadCIDRs(RU_IPV6_URL),
    ]);
    if (ruV4Raw.length === 0) throw new Error("IPverse RU IPv4 list is empty");
    if (ruV6Raw.length === 0) throw new Error("IPverse RU IPv6 list is empty");

    const ruV4 = mergeCidr(ruV4Raw);
    const ruV6 = mergeCidr(ruV6Raw);
    const ruRoutes = mergeCidr([...ruV4, ...ruV6]);
    console.log(`ru: ${ruRoutes.length} CIDRs (${ruV4.length} v4 + ${ruV6.length} v6)`);

    // ---- EU: Public Internet - Technical Ranges - RU ----
    const euV4 = excludeCidr([IPV4_BASE], [...IPV4_TECHNICAL, ...ruV4]);
    const euV6 = excludeCidr([IPV6_BASE], ruV6);
    const euRoutes = mergeCidr([...euV4, ...euV6]);
    console.log(`eu: ${euRoutes.length} CIDRs (${euV4.length} v4 + ${euV6.length} v6)`);

    // ---- Validation ----
    validateRoutes(ruRoutes, "ru");
    validateRoutes(euRoutes, "eu");

    // RU and EU must be fully disjoint, including containment overlaps
    // (e.g. RU=1.2.0.0/16 and EU=1.2.3.0/24). Use a sorted-merge scan over
    // parsed [start,end] ranges so this stays O(n+m) instead of O(n*m).
    const overlap = findCidrOverlap(ruRoutes, euRoutes);
    if (overlap) {
        throw new Error(`eu and ru overlap: ${overlap[0]} <> ${overlap[1]}`);
    }

    // EU must not overlap any listed IPv4 technical/special-use range
    // (either contained by or containing one of them).
    for (const c of euRoutes) {
        if (isV6(c)) continue;
        const tech = IPV4_TECHNICAL.find(
            (t) => containsCidr(t, c) || containsCidr(c, t),
        );
        if (tech) {
            throw new Error(
                `eu contains technical/special-use CIDR ${c} (overlaps ${tech})`,
            );
        }
    }

    // IPv6 part of EU must lie within 2000::/3.
    for (const c of euRoutes) {
        if (isV6(c) && !containsCidr(IPV6_BASE, c)) {
            throw new Error(`eu IPv6 CIDR ${c} is outside ${IPV6_BASE}`);
        }
    }

    // ---- Update only the routes lists, preserve everything else ----
    ruConn.routes = ruRoutes;
    euConn.routes = euRoutes;

    writeFileSync(POLICY_FILE, JSON.stringify(policy, null, 2) + "\n");
    console.log(`${POLICY_FILE}: updated`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
