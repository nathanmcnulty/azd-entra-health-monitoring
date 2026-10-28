"""Closed nonsecret projection oracle, not an authenticated provider reader."""
import re
import math
from control import Refused, freeze_plan, digest
from build_fixture import oracle_bindings


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def context_bindings(plan):
    p = freeze_plan(plan)
    # Bodies contain only the unmaterialized empty secure binding. Never pass
    # an actual callback value here or make a digest of a secret binding.
    return {'artifacts': oracle_bindings(), 'configuration': digest(p['bodies']),
            'attempt': p['attempt'], 'plan': digest(p), 'group': p['group'], 'subscription': p['subscription']}


def check_oracle(record, expected):
    if type(record) is not dict or set(record) != {"bindings", "parent", "stubs", "complete", "receivers"}:
        raise Refused("oracle-shape")
    if expected['bindings'] != context_bindings(expected['plan']) or record["bindings"] != expected["bindings"]:
        raise Refused("oracle-binding")
    if (expected['attempt'] != expected['plan']['attempt'] or expected['parentWorkflow'] != 'm21-lifecycle-create'
            or expected['stubWorkflow'] != 'm21-response-stub'):
        raise Refused('attempt-config-context')
    parent = record["parent"]
    if type(parent) is not dict or set(parent) != {"workflow", "run", "intents", "actions", "providerStatus"}:
        raise Refused("parent-shape")
    if (parent["workflow"] != expected["parentWorkflow"] or parent["run"] != expected["parentRun"]
            or parent["providerStatus"] != "Succeeded"):
        raise Refused("parent-provider-identity")
    tuples = []
    for kind, action in (("list", "List_subscriptions"), ("create", "Create_subscription")):
        tuples.append({"attempt": expected["attempt"], "case": "lifecycle-create",
                       "request": expected["attempt"] + "-" + kind,
                       "parentWorkflow": parent["workflow"], "parentRun": parent["run"], "parentAction": action})
    if parent["intents"] != tuples or type(parent["actions"]) is not list or len(parent["actions"]) != 2:
        raise Refused("one-to-one-intents")
    for action, correlation in zip(parent["actions"], tuples):
        if (set(action) != {"name", "status", "start", "end"} or action["name"] != correlation["parentAction"]
                or action["status"] != "Succeeded" or not number(action['start'])
                or not number(action['end']) or action["start"] >= action["end"]):
            raise Refused("parent-action-observation")
    if parent["actions"][0]["end"] > parent["actions"][1]["start"]:
        raise Refused("parent-order")
    stubs = record["stubs"]
    if type(stubs) is not list or len(stubs) != 2:
        raise Refused("exactly-two-stub-runs")
    seen = set()
    for index, (stub, correlation, body, status) in enumerate(zip(stubs, tuples,
            ({"value": []}, {"id": "fixture-created-subscription"}), (200, 201))):
        if type(stub) is not dict or set(stub) != {"workflow", "run", "status", "event", "response", "start", "end"}:
            raise Refused("stub-shape")
        if (stub["workflow"] != expected["stubWorkflow"] or type(stub["run"]) is not str
                or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", stub["run"]) or stub["run"] in seen
                or stub["status"] != "Succeeded"):
            raise Refused("distinct-stub-provider-runs")
        seen.add(stub["run"])
        event = {**correlation, "stubRun": stub["run"], "responseStatus": status, "responseBody": body}
        response = {"action": "Respond_" + ("list" if index == 0 else "create"),
                    "status": "Succeeded", "statusCode": status, "body": body}
        if stub["event"] != event or stub["response"] != response:
            raise Refused("independent-response-semantics-required")
        action = parent["actions"][index]
        if not number(stub['start']) or not number(stub['end']) or not action["start"] <= stub["start"] < stub["end"] <= action["end"]:
            raise Refused("request-stub-time-binding")
    if record["complete"] != {**tuples[1], "branch": "empty-list-create", "status": "Succeeded"}:
        raise Refused("branch-proof")
    receivers = record['receivers']
    if type(receivers) is not list or len(receivers) != 2:
        raise Refused('two-receiver-observations-required')
    for i, case in enumerate(('receiver-duplicate', 'receiver-mismatch')):
        r = receivers[i]
        required = {'case', 'workflow', 'run', 'status', 'iterationCount', 'selectedValid', 'alertIds', 'deliveryStatuses', 'deliveryOutputs', 'checkNotificationResult'}
        if type(r) is not dict or set(r) != required or r['case'] != case or r['workflow'] != 'm21-' + case or type(r['run']) is not str or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}',r['run']):
            raise Refused('receiver-provider-identity')
        if r['status'] != 'Succeeded' or type(r['iterationCount']) is not int or r['iterationCount'] != 1:
            raise Refused('receiver-iteration-or-status')
        expected_selected = [True, True] if i == 0 else [False]
        if (r['selectedValid'] != expected_selected or any(type(v) is not bool for v in r['selectedValid'])
                or r['alertIds'] != (['fixture-alert-01','fixture-alert-01'] if i == 0 else ['fixture-alert-02'])
                or r['checkNotificationResult'] is not (i == 0)
                or r['deliveryStatuses'] != (['Succeeded'] if i == 0 else ['Skipped'])
                or r['deliveryOutputs'] != ([{'fixtureDelivery':'synthetic','sourceAction':'Post_message_in_a_chat_or_channel'}] if i == 0 else [])):
            raise Refused('receiver-function-proof')
    return {"correlationsValid": True, "nativeQualified": False, "executionAuthorized": False,
            "evidenceMode": "caller-projected-observations-not-authenticated-provider-proof"}
