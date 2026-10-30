"""Portable static contract checks; does not claim to compile or execute Swift."""
import hashlib
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[4]
package = root / "src/QNotch.Mac"
source = (package / "Sources/QNotchMacCore/ProductAnalytics.swift").read_text(encoding="utf-8")
catalog = json.loads((root / "tests/fixtures/analytics/catalog-v1.json").read_text(encoding="utf-8-sig"))
vectors = json.loads((root / "tests/fixtures/analytics/identity-v1.json").read_text(encoding="utf-8-sig"))
actions = source.split("public static let actions:", 1)[1].split("public static let targets:", 1)[0]
native = {module: set(re.findall(r'"([a-z_]+)"', values)) for module, values in re.findall(r'"([a-z_]+)": \[(.*?)\]', actions)}
assert native, "Native action catalog was not found"
for module, values in native.items():
    assert values <= set(catalog["modules"].get(module, [])), (module, values - set(catalog["modules"].get(module, [])))
targets = set(re.findall(r'"([a-z_]+)"', source.split("public static let targets:", 1)[1].split("public static let surfaces:", 1)[0]))
assert targets <= set(catalog["targets"]), targets - set(catalog["targets"])
calls = 0
for path in (package / "Sources/QNotchMac").rglob("*.swift"):
    text = path.read_text(encoding="utf-8")
    for module, action in re.findall(r'Analytics.record\("([a-z_]+)", "([a-z_]+)"', text):
        assert action in native.get(module, set()), (path.name, module, action)
        calls += 1
    for target in re.findall(r'Analytics.setting\("([a-z_]+)"', text):
        assert target in targets, (path.name, target)
for vector in vectors["vectors"]:
    assert hashlib.sha256(vector["raw"].encode()).hexdigest() == vector["sha256"]
configuration = json.loads((package / "Sources/QNotchMac/Resources/analytics-config.json").read_text())
assert set(configuration) == {"key", "host"}
assert configuration["host"] == "https://eu.i.posthog.com"
print(f"Mac analytics contract: {len(native)} modules, {sum(map(len, native.values()))} actions, {len(targets)} targets, {calls} literal command sites, {len(vectors['vectors'])} hash vectors passed")
