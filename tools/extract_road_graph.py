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
            # Most DecalRoad objects are cosmetic decals (lane paint, cracks, tire marks,
            # gutters, crosswalk paint...) drawn over the real road surface. Confirmed
            # empirically across every official map: the actual AI navigation layer is
            # always material "road_invisible" — everything else is visual-only and would
            # massively over-count junctions if included.
            if obj.get("material") != "road_invisible":
                continue
            nodes = obj.get("nodes", [])
            if len(nodes) < 2:
                continue
            width = _average_width(nodes)
            road_class = classify_road_class(width)
            segments.append(
                {
                    "id": obj.get("persistentId"),
                    "sourceFile": info.filename,
                    "nodes": nodes,  # each node: [x, y, z, width]
                    "oneWay": bool(obj.get("oneWay", False)),
                    "lanesLeft": obj.get("lanesLeft"),
                    "drivability": obj.get("drivability", 1),
                    "material": obj.get("material"),
                    "width": round(width, 2),
                    # Heuristic only (road width -> class), inspired by OSM's highway=*
                    # hierarchy — BeamNG does not encode a road class natively. Needs
                    # manual review / ruleset override (section 4.2, section 6).
                    "roadClass": road_class,
                    "speedLimit": DEFAULT_SPEED_LIMIT_KMH.get(road_class),
                }
            )
    return segments


# Heuristic road-width thresholds (metres) -> class, and a default speed limit (km/h)
# per class. Both are placeholders standing in for data BeamNG does not encode natively
# — meant to be overridden by a country ruleset (section 6) or manual correction, not
# treated as ground truth.
ROAD_CLASS_WIDTH_THRESHOLDS = [
    (14.0, "trunk"),
    (9.0, "primary"),
    (6.5, "secondary"),
    (0.0, "residential"),
]
DEFAULT_SPEED_LIMIT_KMH = {
    "trunk": 110,
    "primary": 80,
    "secondary": 50,
    "residential": 30,
}


def _average_width(nodes: list[list[float]]) -> float:
    widths = [n[3] for n in nodes if len(n) > 3]
    return sum(widths) / len(widths) if widths else 0.0


def classify_road_class(width: float) -> str:
    for threshold, name in ROAD_CLASS_WIDTH_THRESHOLDS:
        if width >= threshold:
            return name
    return "residential"


def load_signals(zf: zipfile.ZipFile, level_name: str) -> dict | None:
    path = f"levels/{level_name}/signals.json"
    try:
        return json.loads(zf.read(path).decode("utf-8"))
    except KeyError:
        return None


def _dist(a, b) -> float:
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def _normalize(v):
    length = math.sqrt(sum(c * c for c in v))
    if length < 1e-6:
        return [0.0, 0.0, 0.0]
    return [c / length for c in v]


def _tangent_away_from_endpoint(nodes: list[list[float]], end: str) -> list[float]:
    """Direction pointing from the junction endpoint back into the road (away from it)."""
    if end == "start":
        a, b = nodes[0][:3], nodes[1][:3]
    else:
        a, b = nodes[-1][:3], nodes[-2][:3]
    return _normalize([b[i] - a[i] for i in range(3)])


def cluster_junctions(segments: list[dict], radius: float = JUNCTION_CLUSTER_RADIUS) -> list[dict]:
    """Group nearby segment endpoints into junction candidates (naive greedy clustering)."""
    endpoints = []
    for seg in segments:
        nodes = seg["nodes"]
        endpoints.append((seg["id"], "start", nodes[0][:3], _tangent_away_from_endpoint(nodes, "start")))
        endpoints.append((seg["id"], "end", nodes[-1][:3], _tangent_away_from_endpoint(nodes, "end")))

    clusters: list[dict] = []
    for seg_id, end, pos, tangent in endpoints:
        match = next((c for c in clusters if _dist(pos, c["position"]) <= radius), None)
        if match is None:
            clusters.append({"position": list(pos), "members": [(seg_id, end, tangent)]})
        else:
            n = len(match["members"]) + 1
            match["position"] = [
                (match["position"][i] * (n - 1) + pos[i]) / n for i in range(3)
            ]
            match["members"].append((seg_id, end, tangent))

    for c in clusters:
        c["segmentIds"] = {m[0] for m in c["members"]}

    # A real junction needs 2+ distinct segments meeting; a lone endpoint is a dead end.
    return [c for c in clusters if len(c["segmentIds"]) >= 2]


def classify_cluster(cluster: dict, straight_angle_deg: float = 150.0) -> str:
    """Distinguish a real crossing from a road merely split into consecutive DecalRoad
    pieces (same logical street, no other street actually meets it here).

    With exactly two segments meeting, if their tangents (pointing away from the
    junction, back into each segment) are nearly opposite (>150 degrees apart), the
    road is essentially going straight through the point -> "continuation".
    Three or more distinct segments, or a sharp/right-angle meeting of two segments,
    is treated as a real "junction" candidate.
    """
    distinct = list(cluster["segmentIds"])
    if len(distinct) >= 3:
        return "junction"

    # exactly two distinct segments — take one representative tangent per segment
    tangents_by_seg = {}
    for seg_id, _end, tangent in cluster["members"]:
        tangents_by_seg.setdefault(seg_id, tangent)
    if len(tangents_by_seg) < 2:
        return "junction"  # shouldn't happen given the >=2 filter, but stay safe

    t1, t2 = list(tangents_by_seg.values())[:2]
    dot = sum(t1[i] * t2[i] for i in range(3))
    dot = max(-1.0, min(1.0, dot))
    angle = math.degrees(math.acos(dot))
    return "continuation" if angle >= straight_angle_deg else "junction"


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
            # Per-instance id + facing direction, so core.lua can pick, at runtime, the
            # specific physical light that governs a given approach direction (an
            # intersection's "group" bundles instances facing every direction, e.g. both
            # NS and EW) and query its live state via the confirmed real API:
            # extensions.core_trafficSignals.getElementById(id):getState()
            # (read directly from lua/ge/extensions/core/trafficSignals.lua in the game
            # install -- see docs/ARCHITECTURE.md section 4).
            best["trafficLightInstances"] = [
                {"id": i["id"], "dir": i["dir"], "controllerId": i.get("controllerId")}
                for i in instances
                if "id" in i and "dir" in i
            ]


def build_graph(level_name: str, zf: zipfile.ZipFile) -> dict:
    segments = load_decal_roads(zf)
    signals = load_signals(zf, level_name)
    clusters = cluster_junctions(segments)
    match_traffic_lights(clusters, signals)

    junctions = []
    for i, c in enumerate(clusters):
        base_type = classify_cluster(c)
        # A traffic light is never a mere continuation of the same road.
        junction_type = "trafficLight" if "trafficLightGroupId" in c else base_type
        junctions.append(
            {
                "id": f"j_{i:04d}",
                "position": c["position"],
                "type": junction_type,
                "trafficLightGroupId": c.get("trafficLightGroupId"),
                "trafficLightControllerIds": c.get("trafficLightControllerIds"),
                "trafficLightInstances": c.get("trafficLightInstances"),
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
        # Raw controller/sequence definitions from signals.json, kept as reference
        # data (e.g. for an in-game debug overlay comparing our reading of a light
        # to its actual cycle). core.lua does not self-simulate light timing from
        # this -- it queries the game's own live trafficSignals state instead, since
        # BeamNG is already animating the real light poles and our AI must match
        # what the player sees, not run a parallel clock that could drift out of
        # sync (see docs/ARCHITECTURE.md section 4, trafficLights.lua).
        "trafficLightControllers": (signals or {}).get("controllers", []),
        "trafficLightSequences": (signals or {}).get("sequences", []),
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
    n_cont = sum(1 for j in graph["junctions"] if j["type"] == "continuation")
    n_real = sum(1 for j in graph["junctions"] if j["type"] == "junction")
    print(
        f"{level_name}: {len(graph['segments'])} segments, {len(graph['junctions'])} candidates total "
        f"-> {n_real} real junctions, {n_cont} continuations, {n_lit} traffic-light junctions "
        f"-> {out_path}"
    )


if __name__ == "__main__":
    main()
