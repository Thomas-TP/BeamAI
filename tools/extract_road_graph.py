"""Extract a semantic road graph from a packed BeamNG.drive level .zip.

No running game instance and no BeamNG.tech/BeamNGpy required: road geometry
(DecalRoad) and traffic-light data (signals.json) are plain JSON already
present in the level archive shipped with the standard BeamNG.drive install.

Usage:
    python extract_road_graph.py "<path to>/content/levels/west_coast_usa.zip"
    python extract_road_graph.py "<path to>/content/levels/gridmap_v2.zip" -o gridmap.roadgraph.json

Output: a JSON file matching the semantic road graph schema described in
docs/ARCHITECTURE.md (segments + parkingZones stub + junction candidates).
This is a first pass: junction *detection* and traffic-light *matching* are
automatic, but junction *priority rules* (stop / give-way / right-of-way) are
left as "unclassified" for manual or ruleset-driven assignment (section 4.2
and section 6 of the architecture doc) since BeamNG does not encode those
natively.
"""
from __future__ import annotations

import argparse
import json
import math
import zipfile
from collections import defaultdict
from pathlib import Path

JUNCTION_CLUSTER_RADIUS = 6.0   # metres: endpoints closer than this are one junction
TRAFFIC_LIGHT_MATCH_RADIUS = 25.0  # metres: max distance from light group to a junction


def iter_jsonl_objects(text: str):
    """BeamNG *.level.json files are JSON-lines (one object per line), not a JSON array."""
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue


def load_decal_roads(zf: zipfile.ZipFile) -> list[dict]:
    segments = []
    for info in zf.infolist():
        if not info.filename.endswith("items.level.json"):
            continue
        text = zf.read(info.filename).decode("utf-8", errors="ignore")
        for obj in iter_jsonl_objects(text):
            if obj.get("class") != "DecalRoad":
                continue
            nodes = obj.get("nodes", [])
            if len(nodes) < 2:
                continue
            segments.append(
                {
                    "id": obj.get("persistentId"),
                    "sourceFile": info.filename,
                    "nodes": nodes,  # each node: [x, y, z, width]
                    "oneWay": bool(obj.get("oneWay", False)),
                    "lanesLeft": obj.get("lanesLeft"),
                    "drivability": obj.get("drivability", 1),
                    "material": obj.get("material"),
                    "roadClass": "unknown",  # not encoded natively; enrich later (section 4.2)
                    "speedLimit": None,      # not encoded natively; enrich later (section 4.2)
                }
            )
    return segments


def load_signals(zf: zipfile.ZipFile, level_name: str) -> dict | None:
    path = f"levels/{level_name}/signals.json"
    try:
        return json.loads(zf.read(path).decode("utf-8"))
    except KeyError:
        return None


def _dist(a, b) -> float:
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def cluster_junctions(segments: list[dict], radius: float = JUNCTION_CLUSTER_RADIUS) -> list[dict]:
    """Group nearby segment endpoints into junction candidates (naive greedy clustering)."""
    endpoints = []
    for seg in segments:
        nodes = seg["nodes"]
        endpoints.append((seg["id"], nodes[0][:3]))
        endpoints.append((seg["id"], nodes[-1][:3]))

    clusters: list[dict] = []
    for seg_id, pos in endpoints:
        match = next((c for c in clusters if _dist(pos, c["position"]) <= radius), None)
        if match is None:
            clusters.append({"position": list(pos), "segmentIds": {seg_id}})
        else:
            n = len(match["segmentIds"]) + 1
            match["position"] = [
                (match["position"][i] * (n - 1) + pos[i]) / n for i in range(3)
            ]
            match["segmentIds"].add(seg_id)

    # A real junction needs 2+ distinct segments meeting; a lone endpoint is a dead end.
    return [c for c in clusters if len(c["segmentIds"]) >= 2]


def match_traffic_lights(clusters: list[dict], signals: dict | None, radius: float = TRAFFIC_LIGHT_MATCH_RADIUS) -> None:
    if not signals:
        return
    groups: dict[str, list[dict]] = defaultdict(list)
    for inst in signals.get("instances", []):
        group_name = inst.get("group") or f"single_{inst.get('id')}"
        groups[group_name].append(inst)

    for group_name, instances in groups.items():
        center = [sum(i["pos"][a] for i in instances) / len(instances) for a in range(3)]
        best, best_d = None, None
        for c in clusters:
            d = _dist(center, c["position"])
            if d <= radius and (best_d is None or d < best_d):
                best, best_d = c, d
        if best is not None:
            best["trafficLightGroupId"] = group_name
            best["trafficLightControllerIds"] = sorted(
                {i["controllerId"] for i in instances if "controllerId" in i}
            )


def build_graph(level_name: str, zf: zipfile.ZipFile) -> dict:
    segments = load_decal_roads(zf)
    signals = load_signals(zf, level_name)
    clusters = cluster_junctions(segments)
    match_traffic_lights(clusters, signals)

    junctions = []
    for i, c in enumerate(clusters):
        junctions.append(
            {
                "id": f"j_{i:04d}",
                "position": c["position"],
                "type": "trafficLight" if "trafficLightGroupId" in c else "unclassified",
                "trafficLightGroupId": c.get("trafficLightGroupId"),
                "trafficLightControllerIds": c.get("trafficLightControllerIds"),
                "priorityRule": None,  # section 4.2 / 6 — assign via ruleset or manual editor
                "approaches": sorted(c["segmentIds"]),
            }
        )

    return {
        "map": level_name,
        "ruleset": None,  # pick from section 6 (e.g. "fr_priority_to_right", "usa_4way_stop")
        "segments": segments,
        "parkingZones": [],  # section 4.3bis — not derivable from DecalRoad, needs its own pass
        "junctions": junctions,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("level_zip", help="Path to the level .zip (e.g. content/levels/west_coast_usa.zip)")
    ap.add_argument("-o", "--output", help="Output JSON path (default: <level>.roadgraph.json)")
    args = ap.parse_args()

    level_zip = Path(args.level_zip)
    level_name = level_zip.stem
    with zipfile.ZipFile(level_zip) as zf:
        graph = build_graph(level_name, zf)

    out_path = Path(args.output) if args.output else Path(f"{level_name}.roadgraph.json")
    out_path.write_text(json.dumps(graph, indent=2), encoding="utf-8")

    n_lit = sum(1 for j in graph["junctions"] if j["type"] == "trafficLight")
    print(
        f"{level_name}: {len(graph['segments'])} segments, "
        f"{len(graph['junctions'])} junction candidates ({n_lit} matched to traffic lights) "
        f"-> {out_path}"
    )


if __name__ == "__main__":
    main()
