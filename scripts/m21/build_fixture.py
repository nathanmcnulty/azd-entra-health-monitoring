"""Deterministic local derivative; preserves the original M20/M1 artifacts."""
import copy
import hashlib
import json
from pathlib import Path
from control import canonical, digest

ROOT = Path(__file__).resolve().parents[2]


def tuple_value(action, request):
    return {"attempt": "@parameters('FixtureAttemptId')", "case": "lifecycle-create",
            "request": "@concat(parameters('FixtureAttemptId'), '-" + request + "')",
            "parentWorkflow": "@workflow().name", "parentRun": "@workflow().run.name",
            "parentAction": action}


def make_fixture():
    old = ROOT / "validation/m20-generated/cases"
    manifest_path = old.parent / 'manifest.json'
    if hashlib.sha256(manifest_path.read_bytes()).hexdigest() != 'e6d3b7282ab5cfc12dfd7c1d70af4bd43d61d792de2dfa8c02b5a4ebca11e96d':
        raise ValueError('Original frozen manifest drift')
    manifest = json.loads(manifest_path.read_bytes())
    for name, expected in manifest['generatedFiles'].items():
        if hashlib.sha256((old.parent / name).read_bytes()).hexdigest() != expected.lower():
            raise ValueError('Original frozen file drift')
    load = lambda p: json.loads(p.read_text(encoding="utf-8-sig"))
    duplicate = load(old / "receiver-duplicate-batch/definition.json")
    mismatch = load(old / "receiver-mismatched-state/definition.json")
    lifecycle = load(old / "lifecycle-create/definition.json")
    lifecycle["parameters"]["FixtureAttemptId"] = {"type": "string"}
    actions = lifecycle["actions"]
    actions["Observe_list_intent"] = {"type": "Compose", "runAfter": {},
                                       "inputs": tuple_value("List_subscriptions", "list")}
    actions["List_subscriptions"]["runAfter"] = {"Observe_list_intent": ["Succeeded"]}
    actions["List_subscriptions"]["inputs"]["body"] = tuple_value("List_subscriptions", "list")
    create = actions["Check_existing_subscription"]["actions"]
    create["Observe_create_intent"] = {"type": "Compose", "runAfter": {},
                                         "inputs": tuple_value("Create_subscription", "create")}
    create["Create_subscription"]["runAfter"] = {"Observe_create_intent": ["Succeeded"]}
    create["Create_subscription"]["inputs"]["body"] = tuple_value("Create_subscription", "create")
    create["Observe_create_branch_complete"] = {"type": "Compose",
        "runAfter": {"Create_subscription": ["Succeeded"]},
        "inputs": {**tuple_value("Create_subscription", "create"), "branch": "empty-list-create"}}
    # Unselected branches cannot silently introduce new stub operations.
    # They remain in this derivative but the fixed stub refuses them.
    params = {"FixtureAttemptId": {"type": "string"}}
    schema = {"type": "object", "additionalProperties": False,
              "properties": {key: {"type": "string", "maxLength": 128}
                             for key in tuple_value("x", "x")},
              "required": list(tuple_value("x", "x"))}
    cases = {}
    for kind, action, status, body in (("list", "List_subscriptions", 200, {"value": []}),
                                       ("create", "Create_subscription", 201, {"id": "fixture-created-subscription"})):
        observed = {key: "@triggerBody()?['" + key + "']" for key in tuple_value(action, kind)}
        observed.update({"stubRun": "@workflow().run.name", "responseStatus": status, "responseBody": body})
        cases[kind] = {"case": action, "actions": {
            "Observe_" + kind: {"type": "Compose", "runAfter": {}, "inputs": observed},
            "Respond_" + kind: {"type": "Response", "kind": "Http",
                "runAfter": {"Observe_" + kind: ["Succeeded"]},
                "inputs": {"statusCode": status, "body": "@outputs('Observe_" + kind + "')?['responseBody']"}}}}
    invalid = {"type": "Terminate", "inputs": {"runStatus": "Failed",
               "runError": {"code": "FixtureCorrelationRejected", "message": "Invalid fixture correlation."}}}
    guard = "@and(equals(triggerBody()?['attempt'], parameters('FixtureAttemptId')), equals(triggerBody()?['case'], 'lifecycle-create'), equals(triggerBody()?['parentWorkflow'], 'm21-lifecycle-create'), not(empty(triggerBody()?['parentRun'])), equals(triggerBody()?['request'], concat(parameters('FixtureAttemptId'), if(equals(triggerBody()?['parentAction'], 'List_subscriptions'), '-list', '-create'))))"
    stub = {"$schema": lifecycle["$schema"], "contentVersion": "2.0.0.0", "parameters": params,
            "triggers": {"When_a_HTTP_request_is_received": {"type": "Request", "kind": "Http",
                "inputs": {"method": "POST", "schema": schema}}},
            "actions": {"Validate_fixture_request": {"type": "If", "runAfter": {}, "expression": guard,
                "actions": {"Select_fixture_response": {"type": "Switch", "runAfter": {},
                    "expression": "@triggerBody()?['parentAction']", "cases": cases,
                    "default": {"actions": {"Reject_unknown_action": copy.deepcopy(invalid)}}}},
                "else": {"actions": {"Reject_correlation": copy.deepcopy(invalid)}}}}, "outputs": {}}
    definitions = {"receiver-duplicate": duplicate, "receiver-mismatch": mismatch,
                   "lifecycle-create": lifecycle, "response-stub": stub}
    inputs = {"receiver-duplicate": load(old / "receiver-duplicate-batch/configuration.json")["fixtureInput"],
              "receiver-mismatch": load(old / "receiver-mismatched-state/configuration.json")["fixtureInput"],
              "lifecycle-create": load(old / "lifecycle-create/configuration.json")["fixtureInput"]}
    # Executed path accounting includes control-flow containers and nested stubs.
    # Parent original path: 6 root actions + Create HTTP = 7; now +3 Compose =10.
    # Each stub path: If + Switch + Compose + Response =4; two stubs =>8.
    parent_root = len(lifecycle["actions"])
    lifecycle_actions = parent_root + len(create) + 2 * (1 + 1 + 1 + 1)
    def all_actions(actions, multiplier=1):
        # Explicit WDL grammar, never search arbitrary input objects for 'type'.
        found = []
        for node in actions.values():
            found.extend([node] * multiplier)
            loops = 2 if node['type'] == 'Foreach' else 1
            if 'actions' in node:
                found.extend(all_actions(node['actions'], multiplier * loops))
            if 'else' in node:
                found.extend(all_actions(node['else'].get('actions', {}), multiplier))
            for case in node.get('cases', {}).values():
                found.extend(all_actions(case.get('actions', {}), multiplier))
            if 'default' in node:
                found.extend(all_actions(node['default'].get('actions', {}), multiplier))
        return found
    reservations = {}
    for alias in ("receiver-duplicate", "receiver-mismatch", "lifecycle-create"):
        nodes = all_actions(definitions[alias]["actions"])
        http = sum(n["type"] == "Http" for n in nodes)
        reservations[alias] = {"triggers": 1 + http, "actions": len(nodes) + 4 * http, "bytes": 16384}
    profile = {"id": "health-logic-correlated-fixture", "version": "2.0.0",
        "sourceBase": "d033f4b5036977000a1a5ba820c440a269951463",
        "definitions": {k: hashlib.sha256(canonical(v)).hexdigest() for k, v in definitions.items()},
        "accounting": {"outer": 3, "nested": 2, "inclusive": 5, "retries": 0,
                       "actions": 14 + 9 + lifecycle_actions, "lifecycleActions": lifecycle_actions,
                       "parentRoot": parent_root, "createBranch": len(create), "stubPathPerRun": 4,
                       "actionCeiling": 128, "triggerCeiling": 20,
                       "conservativeReservations": reservations,
                       "payloadReservationPerCase": 16384, "logPlanningBytes": 104857600},
        "proof": {"nativeQualified": False, "executionAuthorized": False, "publicationAuthorized": False,
                  "required": "provider-correlated parent/stub action records and exact bindings; no redaction fallback"}}
    return definitions, inputs, profile


def source_hashes():
    return {name: hashlib.sha256((Path(__file__).parent / name).read_bytes()).hexdigest()
            for name in ('build_fixture.py', 'control.py', 'oracle.py', 'live_io.py', 'native.py', 'ingress-policy.json')}


def deploy_bodies(attempt, operator_cidr, stub_cidrs):
    definitions, _, _ = make_fixture()
    parameters = {
        'receiver-duplicate': {'GraphSubscriptionClientState': {'value': 'fixture-client-state'}, 'TargetChannelDisplayName': {'value': 'Fixture Channel'}},
        'receiver-mismatch': {'GraphSubscriptionClientState': {'value': 'fixture-client-state'}, 'TargetChannelDisplayName': {'value': 'Fixture Channel'}},
        'lifecycle-create': {'GraphSubscriptionClientState': {'value': 'fixture-client-state'}, 'FixtureAttemptId': {'value': attempt}, 'FixtureStubCallback': {'value': ''}},
        'response-stub': {'FixtureAttemptId': {'value': attempt}}}
    return {alias: {'location': 'westus2', 'properties': {'state': 'Disabled', 'definition': definition,
        'parameters': parameters[alias], 'accessControl': {'triggers': {'allowedCallerIpAddresses':
        [{'addressRange': value} for value in ((stub_cidrs or ['UNRESOLVED_NESTED_INGRESS']) if alias == 'response-stub'
             else [operator_cidr or 'UNRESOLVED_OPERATOR_INGRESS'])]}}}} for alias, definition in definitions.items()}


def oracle_bindings():
    definitions, inputs, profile = make_fixture()
    return {'profile': digest(profile), 'definitions': profile['definitions'], 'inputs': digest(inputs)}


def candidate_plan(context):
    _, inputs, profile = make_fixture()
    return {**context, 'artifacts': profile['definitions'], 'inputs': inputs,
        'bodies': deploy_bodies(context['attempt'], context['operator_cidr'], context['stub_cidrs']),
        'workloads': profile['accounting']['conservativeReservations'], 'source_hashes': source_hashes()}


def write_candidate(output):
    output = Path(output)
    output.mkdir(exist_ok=False)
    definitions, inputs, profile = make_fixture()
    values = {**{name + ".json": d for name, d in definitions.items()},
              "inputs.json": inputs, "profile.json": profile}
    for name, value in values.items():
        (output / name).write_bytes(canonical(value))
    manifest = {"kind": "m21-candidate-artifacts", "builderSha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "files": {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in values},
                "nativeQualified": False, "executionAuthorized": False}
    (output / "manifest.json").write_bytes(canonical(manifest))
    return manifest


if __name__ == "__main__":
    import sys
    write_candidate(sys.argv[1])
