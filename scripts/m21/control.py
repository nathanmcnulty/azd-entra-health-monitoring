"""Bounded fixture controller. Public live entrypoint always refuses.

Injected offline transports remain distinct from exact-authority native workers.
No retries. Capabilities and raw bodies never enter the durable journal.
"""
import hashlib
import ipaddress
import json
import math
import os
import re
import time
from pathlib import Path
from urllib.parse import urlsplit, parse_qs

ALIASES = ("receiver-duplicate", "receiver-mismatch", "lifecycle-create", "response-stub")
NAMES = tuple("m21-" + a for a in ALIASES)
RUN = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")


class Refused(Exception):
    """Fixed safe failure; never wrap a transport exception's text."""


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def strict_json(raw, limit=1048576):
    def pairs(items):
        result = {}
        names = set()
        for key, value in items:
            if key.lower() in names:
                raise Refused("duplicate-json-key")
            names.add(key.lower())
            result[key] = value
        return result
    if len(raw) > limit:
        raise Refused("json-bound")
    try:
        return json.loads(raw, object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(Refused("nonfinite-json")))
    except (ValueError, UnicodeError, RecursionError):
        raise Refused("invalid-json") from None


def one_shot(factory, method, url, headers, body, seconds, selected_headers=None):
    """One HTTP dispatch, streamed 1MiB response, no redirects/retries/cookies.

    factory is injected by offline tests; no default network factory is provided.
    Returned bytes stay transient; caller must never journal secret bodies.
    """
    u = urlsplit(url)
    if (u.scheme != "https" or u.port not in (None, 443) or u.username or u.password
            or u.fragment or not 0 < seconds <= 30 or len(body) > 1048576):
        raise Refused("request-bound")
    connection = None
    deadline = time.monotonic() + seconds
    def remaining():
        value = deadline - time.monotonic()
        if value <= 0:
            raise Refused("request-deadline")
        if connection is not None:
            connection.timeout = value
            sock = getattr(connection, "sock", None)
            if sock is not None:
                sock.settimeout(value)
        return value
    try:
        connection = factory(u.hostname, 443, remaining())
        remaining()
        connection.request(method, u.path + ("?" + u.query if u.query else ""), body, headers)
        remaining()
        response = connection.getresponse()
        data = bytearray()
        while True:
            remaining()
            block = response.read(min(8192, 1048577 - len(data)))
            if not block:
                break
            data.extend(block)
            if len(data) > 1048576:
                raise Refused("response-bound")
        values = [v for k, v in response.getheaders() if k.lower() == "x-ms-workflow-run-id"]
        if len(values) > 1 or (values and not RUN.fullmatch(values[0])):
            raise Refused("ambiguous-provider-run")
        if selected_headers is not None:
            for name in ('azure-asyncoperation', 'location', 'retry-after'):
                found=[v for k,v in response.getheaders() if k.lower()==name]
                if len(found)>1:raise Refused('ambiguous-operation-header')
                if found:selected_headers[name]=found[0]
        remaining()
        return int(response.status), bytes(data), (values[0] if values else None)
    except Exception:
        raise Refused("transport-unknown") from None
    finally:
        if connection is not None:
            try:
                connection.close()
            except Exception:
                raise Refused("transport-close-unknown") from None


def freeze_plan(plan):
    required = {"attempt", "kind", "subscription", "group", "operator_cidr", "stub_cidrs",
                "artifacts", "bodies", "inputs", "workloads", "source_hashes", "disposition"}
    if type(plan) is not dict or set(plan) != required:
        raise Refused("closed-plan")
    p = strict_json(canonical(plan))
    if (not re.fullmatch(r"[a-f0-9]{32}", p["attempt"]) or p["kind"] not in ("normal", "late")
            or not re.fullmatch(r"[a-f0-9-]{36}", p["subscription"])
            or not re.fullmatch(r"rg-azd-health-m21-(normal|late)-[a-f0-9]{12}", p["group"])):
        raise Refused("exact-target")
    if not p['group'].startswith('rg-azd-health-m21-' + p['kind'] + '-'):
        raise Refused('attempt-kind-target')
    # Offline placeholders are explicit blockers, never silently substituted.
    if p["operator_cidr"] is not None:
        net = ipaddress.ip_network(p["operator_cidr"])
        if net.version != 4 or net.prefixlen != 32:
            raise Refused("operator-cidr")
    if p["stub_cidrs"] is not None:
        for cidr in p["stub_cidrs"]:
            net = ipaddress.ip_network(cidr)
            if net.prefixlen == 0:
                raise Refused("broad-stub-cidr")
    if set(p["bodies"]) != set(ALIASES) or set(p["inputs"]) != set(ALIASES[:3]):
        raise Refused("closed-artifacts")
    if set(p["workloads"]) != set(ALIASES[:3]):
        raise Refused("closed-workload")
    for alias in ALIASES[:3]:
        w = p["workloads"][alias]
        if set(w) != {"triggers", "actions", "bytes"} or any(type(v) is not int or v < 0 for v in w.values()):
            raise Refused("workload-types")
    from build_fixture import candidate_plan
    context = {key: p[key] for key in ('attempt', 'kind', 'subscription', 'group', 'operator_cidr', 'stub_cidrs', 'disposition')}
    if p != candidate_plan(context):
        raise Refused('generated-config-artifact-source-accounting-binding')
    return p


class Journal:
    def __init__(self, directory, plan, start=None, mode='offline-test'):
        self.root = Path(directory)
        if any(p.is_symlink() or (hasattr(p, "is_junction") and p.is_junction())
               for p in [self.root, *self.root.parents]):
            raise Refused("journal-link")
        self.root.mkdir(exist_ok=True)
        for leaf in (self.root / 'writer.lock', self.root / 'events.jsonl'):
            if leaf.is_symlink() or (hasattr(leaf, 'is_junction') and leaf.is_junction()):
                raise Refused('journal-leaf-link')
        self.lock = (self.root / "writer.lock").open("a+b")
        self.lock.seek(0)
        if os.name == "nt":
            import msvcrt
            try:
                msvcrt.locking(self.lock.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError:
                self.lock.close()
                raise Refused("writer-busy") from None
        else:
            import fcntl
            try:
                fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                self.lock.close()
                raise Refused("writer-busy") from None
        try:
            path = self.root / "events.jsonl"
            if path.exists():
                self.events = self.inspect(path)
                if start is not None or self.events[0]["data"]["plan"] != digest(plan) or self.events[0]['data']['mode']!=mode:
                    raise Refused("restart-binding")
                self.file = path.open("ab", buffering=0)
            else:
                if start is None:
                    raise Refused("missing-original-ledger")
                self.events = []
                self.file = path.open("xb", buffering=0)
                self.append("header", {"plan": digest(plan), "attempt": plan['attempt'], "start": start, "mode": mode})
        except Exception:
            self.lock.close()
            raise

    @staticmethod
    def inspect(path):
        path = Path(path)
        if path.is_symlink() or (hasattr(path, 'is_junction') and path.is_junction()):
            raise Refused('journal-leaf-link')
        with path.open('rb') as stream:
            raw = stream.read(524289)
        if not raw or len(raw) > 524288 or not raw.endswith(b"\n"):
            raise Refused("torn-or-large-ledger")
        events, previous = [], "0" * 64
        for line in raw.splitlines():
            e = strict_json(line)
            if (type(e) is not dict or set(e) != {"seq", "event", "data", "previous", "hash"}
                    or type(e["seq"]) is not int or e["seq"] != len(events)
                    or e["previous"] != previous):
                raise Refused("ledger-chain")
            unsigned = {k: v for k, v in e.items() if k != "hash"}
            if e["hash"] != digest(unsigned):
                raise Refused("ledger-hash")
            previous = e["hash"]
            shapes = {"header": {"plan", "attempt", "start", "mode"}, "intent": {"id", "phase", "workload", "at"},
                      "test-approved": {"plan"}, "test-ready": {"attempt", "synthetic"},
                      "admitted": {"synthetic"}, "known-run": {"alias", "run"},
                      "test-recovery-gate": {"synthetic", "disposition"}, "waiting": {'reason'},
                      'native-admission': {'packet','decision','ready'},
                      'stub-run': {'alias','run','parent'},
                      'native-recovery-gate': {'disposition','inventory'},
                      'delete-operation': {'url'},
                      'delete-monitor-response': {'status','headersPresent'},
                      'delete-monitor': {'url','kind','retryAfter'},
                      'delete-monitor-poll': {'url','number'},
                      'delete-monitor-status': {'number','state','retryAfter'},
                      'workflow-observed': {'alias','endpoint','definition','configuration'}}
            if e["event"] == "result":
                if set(e["data"]) not in ({"id", "outcome"}, {"id", "outcome", "status"}):
                    raise Refused("result-shape")
            elif e["event"] not in shapes or set(e["data"]) != shapes[e["event"]]:
                raise Refused("ledger-closed-data")
            events.append(e)
        if events[0]["event"] != "header" or events[0]["data"]["mode"] not in ('offline-test','native-observation'):
            raise Refused("ledger-mode")
        header = events[0]['data']
        if (type(header['start']) not in (int, float) or not math.isfinite(header['start'])
                or type(header['plan']) is not str or not re.fullmatch('[a-f0-9]{64}', header['plan'])
                or type(header['attempt']) is not str or not re.fullmatch('[a-f0-9]{32}', header['attempt'])):
            raise Refused('header-types')
        approved = ready = admitted = False
        pending, resolved, invokes, runs = {}, set(), set(), set()
        last = header['start']
        for e in events[1:]:
            event, d = e['event'], e['data']
            if event == 'header':
                raise Refused('duplicate-header')
            if event.startswith('test-') and header['mode']!='offline-test':raise Refused('test-event-in-native-ledger')
            if event.startswith('native-') and header['mode']!='native-observation':raise Refused('native-event-in-test-ledger')
            if event == 'test-approved':
                if d['plan'] != header['plan']: raise Refused('approval-binding')
                approved = True
            elif event == 'test-ready':
                if d['attempt'] != header['attempt'] or d['synthetic'] is not True: raise Refused('ready-binding')
                ready = True
            elif event == 'waiting':
                if d['reason'] != 'material-change': raise Refused('waiting-reason')
                approved = ready = False
            elif event == 'admitted':
                if admitted or not approved or not ready or d['synthetic'] is not True: raise Refused('admission-order')
                admitted = True
            elif event == 'intent':
                if (not admitted or type(d['id']) is not str or not re.fullmatch(r'[A-Za-z0-9:_-]{1,256}', d['id'])
                        or d['id'] in pending or d['id'] in resolved or d['phase'] not in ('normal', 'recovery')
                        or type(d['at']) not in (int, float) or not math.isfinite(d['at']) or d['at'] < last
                        or type(d['workload']) is not dict or set(d['workload']) != {'triggers', 'actions', 'bytes'}
                        or any(type(v) is not int or v < 0 for v in d['workload'].values())):
                    raise Refused('intent-semantics')
                last = d['at']; pending[d['id']] = d
            elif event == 'result':
                if d['id'] not in pending or d['id'] in resolved or d['outcome'] not in ('acknowledged', 'refused', 'unknown', 'not-sent-deadline'):
                    raise Refused('result-without-intent')
                if d['outcome'] in ('acknowledged', 'refused'):
                    if type(d.get('status')) is not int or not 100 <= d['status'] <= 599 or ((200 <= d['status'] < 300) != (d['outcome'] == 'acknowledged')):
                        raise Refused('result-status')
                elif 'status' in d: raise Refused('unknown-status')
                if d['id'].startswith('invoke:') and d['outcome'] == 'acknowledged': invokes.add(d['id'].split(':')[1])
                resolved.add(d['id'])
            elif event == 'known-run':
                if (d['alias'] not in invokes or type(d['run']) is not str or not RUN.fullmatch(d['run'])
                        or (d['alias'], d['run']) in runs): raise Refused('run-without-acknowledged-invoke')
                runs.add((d['alias'], d['run']))
            elif event == 'test-recovery-gate':
                if not admitted or d['synthetic'] is not True or type(d['disposition']) is not str:
                    raise Refused('recovery-gate-type')
            elif event == 'native-admission':
                if admitted or any(type(v) is not str or not re.fullmatch('[a-f0-9]{64}',v) for v in d.values()):raise Refused('native-admission-binding')
                approved=ready=admitted=True
            elif event == 'stub-run':
                if (not admitted or d['alias']!='response-stub' or ('lifecycle-create',d['parent']) not in runs
                        or type(d['run']) is not str or not RUN.fullmatch(d['run']) or (d['alias'],d['run']) in runs):raise Refused('stub-parent-binding')
                runs.add((d['alias'],d['run']))
            elif event == 'native-recovery-gate':
                if not admitted or not re.fullmatch('[a-f0-9]{64}',d['inventory']):raise Refused('native-recovery-gate')
            elif event == 'delete-operation':
                if not admitted or not any(i.startswith('delete:') for i in resolved) or type(d['url']) is not str or '?' in d['url']:raise Refused('delete-operation-binding')
            elif event.startswith('delete-monitor'):
                if not admitted or 'delete:group:none' not in resolved:raise Refused('delete-monitor-without-result')
                prior=[r for r in events[:e['seq']] if r['event']==event]
                responses=[r['data'] for r in events[:e['seq']] if r['event']=='delete-monitor-response']
                monitors=[r['data'] for r in events[:e['seq']] if r['event']=='delete-monitor']
                polls=[r['data'] for r in events[:e['seq']] if r['event']=='delete-monitor-poll']
                statuses=[r['data'] for r in events[:e['seq']] if r['event']=='delete-monitor-status']
                if event=='delete-monitor-response':
                    ack=[r['data'] for r in events[:e['seq']] if r['event']=='result' and r['data']['id']=='delete:group:none']
                    if prior or len(ack)!=1 or ack[0].get('status')!=d['status'] or d['status'] not in (200,202,204) or type(d['headersPresent']) is not bool:raise Refused('delete-monitor-response-binding')
                elif event=='delete-monitor':
                    if (prior or len(responses)!=1 or d['kind'] not in ('none','async','location')
                            or type(d['retryAfter']) is not int or not 0<=d['retryAfter']<=60
                            or (d['kind']=='none')!= (d['url'] is None)
                            or (d['kind']=='none')==responses[0]['headersPresent']
                            or (d['url'] is not None and (type(d['url']) is not str or len(d['url'])>16384))):raise Refused('delete-monitor-binding')
                elif event=='delete-monitor-poll':
                    if (len(monitors)!=1 or monitors[0]['kind']=='none' or d['url']!=monitors[0]['url']
                            or type(d['number']) is not int or d['number']!=len(prior)+1 or d['number']>12
                            or any(s['state'] in ('Succeeded','Failed','Canceled') for s in statuses)):raise Refused('delete-monitor-poll-binding')
                elif event=='delete-monitor-status':
                    if (not polls or d['number']!=polls[-1]['number'] or any(s['number']==d['number'] for s in statuses)
                            or d['state'] not in ('Pending','Succeeded','Failed','Canceled')
                            or type(d['retryAfter']) is not int or not 0<=d['retryAfter']<=60):raise Refused('delete-monitor-status-binding')
            elif event == 'workflow-observed':
                if not admitted or d['alias'] not in ALIASES or any(not re.fullmatch('[a-f0-9]{64}',d[k]) for k in ('definition','configuration')):raise Refused('workflow-observation-binding')
        return events

    def append(self, event, data):
        if len(self.events) >= 1024:
            raise Refused("ledger-exhausted")
        e = {"seq": len(self.events), "event": event, "data": data,
             "previous": self.events[-1]["hash"] if self.events else "0" * 64}
        e["hash"] = digest(e)
        raw = canonical(e) + b"\n"
        if self.file.write(raw) != len(raw):
            raise Refused("journal-partial-write")
        os.fsync(self.file.fileno())
        self.events.append(e)

    def close(self):
        self.file.close()
        self.lock.close()


class Controller:
    def __init__(self, plan, directory, transport=None, clock=time.time, recovery=False):
        self._native = getattr(transport,'offline',None) is False
        if self._native:
            from live_io import Authority, OwnedTransport
            if type(transport) is not OwnedTransport or type(transport.authority) is not Authority or not transport.authority.authorized or transport.authority.plan!=plan:
                raise Refused('native-authority-required')
        elif transport is None or getattr(transport, "offline", None) is not True:
            raise Refused("live-path-disabled-before-auth")
        self._plan = freeze_plan(plan)
        self.transport, self.clock = transport, clock
        self._last = clock()
        if type(self._last) not in (int, float) or not math.isfinite(self._last):
            raise Refused("clock-type")
        self.journal = Journal(directory, self.plan, None if recovery else self._last, 'native-observation' if self._native else 'offline-test')
        self._start = self.journal.events[0]["data"]["start"]
        self._counts = {"normal": 0, "recovery": 0}
        self._intents, self._known_runs = set(), set()
        self._workload = {"triggers": 0, "actions": 0, "bytes": 0}
        self._frozen, self._poisoned, self._admitted = recovery, False, False
        self._approved = self._ready = False
        for e in self.journal.events[1:]:
            d = e["data"]
            if e["event"] == "intent":
                if d["id"] in self._intents or d["phase"] not in self._counts:
                    raise Refused("intent-replay")
                self._intents.add(d["id"])
                self._counts[d["phase"]] += 1
                if type(d["at"]) not in (int, float) or not math.isfinite(d["at"]) or d["at"] < self._start:
                    raise Refused("ledger-clock")
                self._last = max(self._last, d["at"])
                for k, v in d["workload"].items():
                    self._workload[k] += v
            elif e["event"] in ("known-run",'stub-run'):
                self._known_runs.add((d["alias"], d["run"]))
            elif e["event"] not in ("test-approved", "test-ready", "test-recovery-gate", "waiting", "admitted", "result",'native-admission','native-recovery-gate','delete-operation','delete-monitor-response','delete-monitor','delete-monitor-poll','delete-monitor-status','workflow-observed'):
                raise Refused("ledger-event")
        if self._counts["normal"] > 300 or self._counts["recovery"] > 200:
            raise Refused("ledger-budget")
        self._capabilities = {}  # Deliberately lost on restart; never serialized.
        self._endpoints = {}
        for e in self.journal.events:
            if e['event']=='workflow-observed':self._endpoints[e['data']['alias']]=e['data']['endpoint']
        self._completed = {e["data"]["id"] for e in self.journal.events
                          if e["event"] == "result" and e["data"]["outcome"] == "acknowledged"}
        self._has_admission = any(e["event"] in ("admitted",'native-admission') for e in self.journal.events)
        self._recovery_gate = False
        self._response = None
        if self._native:
            a=transport.authority
            binding={'packet':a.packet_hash,'decision':a.decision_hash,'ready':a.ready_hash}
            if recovery:
                entries=[e['data'] for e in self.journal.events if e['event']=='native-admission']
                if entries!=[binding]:raise Refused('original-authority-required-for-recovery')
            else:
                self.append('native-admission',binding)
                self._has_admission=self._admitted=True

    @property
    def plan(self):
        return strict_json(canonical(self._plan))

    @property
    def counts(self):
        return dict(self._counts)

    @property
    def workload(self):
        return dict(self._workload)

    @property
    def known_runs(self):
        return frozenset(self._known_runs)

    def pause_material_change(self):
        self.append('waiting', {'reason': 'material-change'})
        if self._has_admission:
            self._frozen = True
        else:
            self._ready = self._approved = False
            self._admitted = False

    def append(self, event, data):
        try:
            self.journal.append(event, data)
        except Exception:
            self._poisoned = self._frozen = True
            raise Refused("journal-failed-no-dispatch") from None

    def test_approve(self, fingerprint):
        if self._native:raise Refused('synthetic-gate-forbidden')
        if fingerprint != digest(self.plan):
            raise Refused("approval-binding")
        self.append("test-approved", {"plan": fingerprint})
        self._approved = True

    def test_ready(self, attempt, phrase):
        if self._native:raise Refused('synthetic-gate-forbidden')
        if attempt != self.plan["attempt"] or phrase != "I'm ready":
            raise Refused("waiting-for-Nathan-ready")
        self.append("test-ready", {"attempt": attempt, "synthetic": True})
        self._ready = True

    def admit_test(self):
        if self._native:raise Refused('synthetic-gate-forbidden')
        if self._frozen or not self._approved or not self._ready:
            raise Refused("approval-and-ready-separate")
        self.append("admitted", {"synthetic": True})
        self._admitted = True
        self._has_admission = True

    def test_recovery_snapshot(self, facts):
        if self._native:raise Refused('synthetic-gate-forbidden')
        expected = {"disposition": self.plan["disposition"], "quiescent": True,
                    "unknownResources": False, "unfamiliarLocks": False, "unfamiliarRoles": False,
                    "inventoryRepeatedAndComplete": True}
        if facts != expected or not self._has_admission or "group-create:group:none" not in self._completed:
            raise Refused("recovery-ownership-quiescence")
        self.append("test-recovery-gate", {"synthetic": True, "disposition": self.plan["disposition"]})
        self._recovery_gate = True

    def spec(self, operation, alias=None, run=None):
        base = "https://management.azure.com/subscriptions/" + self.plan["subscription"]
        group = base + "/resourceGroups/" + self.plan["group"]
        workflow = None
        if alias is not None:
            if alias not in ALIASES:
                raise Refused("workflow-scope")
            workflow = group + "/providers/Microsoft.Logic/workflows/m21-" + alias
        group_ops = {"group-read": ("GET", "", "2022-09-01"),
                     "group-create": ("PUT", "", "2022-09-01"),
                     "inventory": ("GET", "/resources", "2021-04-01"),
                     "locks": ("GET", "/providers/Microsoft.Authorization/locks", "2016-09-01"),
                     "roles": ("GET", "/providers/Microsoft.Authorization/roleAssignments", "2022-04-01"),
                     "delete": ("DELETE", "", "2022-09-01")}
        body = b""
        if operation in group_ops:
            if alias is not None or run is not None:
                raise Refused("group-selector")
            method, tail, api = group_ops[operation]
            url = group + tail + "?api-version=" + api
            if operation == "group-create":
                body = canonical({"location": "westus2", "tags": {"attempt": self.plan["attempt"]}})
        elif operation == "invoke" and alias in ALIASES[:3] and run is None:
            if alias not in self._capabilities:
                raise Refused("capability-unavailable-after-restart")
            method, url, body = "POST", self._capabilities[alias], canonical(self.plan["inputs"][alias])
        elif workflow:
            if operation in ("run", "actions", "cancel"):
                if (alias, run) not in self._known_runs:
                    raise Refused("unknown-run")
                tail = "/runs/" + run + ({"run": "", "actions": "/actions", "cancel": "/cancel"}[operation])
                method = "POST" if operation == "cancel" else "GET"
            else:
                if run is not None:
                    raise Refused("unexpected-run-selector")
                routes = {"deploy": ("PUT", ""), "bind": ("PUT", ""), "workflow-read": ("GET", ""),
                          "callback-read": ("POST", "/triggers/When_a_HTTP_request_is_received/listCallbackUrl"),
                          "enable": ("POST", "/enable"), "disable": ("POST", "/disable")}
                if operation not in routes:
                    raise Refused("operation-scope")
                method, tail = routes[operation]
                if operation == "deploy":
                    body = canonical(self.plan["bodies"][alias])
                if operation == "bind":
                    if alias != "lifecycle-create" or "response-stub" not in self._capabilities:
                        raise Refused("binding-scope")
                    definition = strict_json(canonical(self.plan["bodies"][alias]))
                    definition["properties"]["parameters"]["FixtureStubCallback"]["value"] = self._capabilities["response-stub"]
                    body = canonical(definition)
            url = workflow + tail + "?api-version=2019-05-01"
        else:
            raise Refused("operation-scope")
        return method, url, body

    def dispatch(self, operation, alias=None, run=None, phase="normal", cost_fresh=True):
        if self._poisoned:
            raise Refused("journal-poisoned")
        if phase not in ("normal", "recovery"):
            raise Refused("phase")
        recovery_ops = {"group-read", "inventory", "locks", "roles", "run", "actions", "disable", "cancel", "delete",'observation','workflow-read'}
        if phase == "recovery" and operation not in recovery_ops:
            raise Refused("recovery-cannot-spend")
        if phase == "recovery" and not self._has_admission:
            raise Refused("recovery-not-admitted")
        if operation == "delete" and (phase != "recovery" or not self._recovery_gate):
            raise Refused("recovery-ownership-quiescence")
        if phase == "normal" and (self._frozen or not self._admitted or not cost_fresh):
            raise Refused("new-work-frozen")
        deadline = self._start + (7200 if phase == "recovery" else 5400)
        now = self._observe_clock(deadline)
        ceiling = 200 if phase == "recovery" else 300
        if self._counts[phase] >= ceiling:
            raise Refused("dispatch-budget")
        method, url, body = self.spec(operation, alias, run)
        if operation == "invoke":
            required = {"enable:" + a + ":none" for a in ALIASES}
            required.add("bind:lifecycle-create:none")
            if not required.issubset(self._completed):
                raise Refused("fixture-not-prepared")
        write = method != "GET"
        intent = operation + ":" + (alias or "group") + ":" + (run or "none")
        if write and intent in self._intents:
            raise Refused("write-never-replayed")
        # All calls, including GET polls, receive unique intent identities.
        if not write:
            intent += ":" + str(len(self.journal.events))
        workload = dict(self.plan["workloads"][alias]) if operation == "invoke" else {"triggers": 0, "actions": 0, "bytes": 0}
        if any(self._workload[k] + workload[k] > limit for k, limit in
               {"triggers": 20, "actions": 128, "bytes": 10485760}.items()):
            raise Refused("workload-reservation-exhausted")
        self.append("intent", {"id": intent, "phase": phase, "workload": workload, "at": now})
        self._intents.add(intent)
        self._counts[phase] += 1
        for k, v in workload.items():
            self._workload[k] += v
        try:
            remaining = deadline - self._observe_clock(deadline)
        except Refused:
            self._frozen = True
            self.append('result', {'id': intent, 'outcome': 'not-sent-deadline'})
            raise Refused('deadline-after-journal') from None
        if remaining <= 0:
            self._frozen = True
            self.append("result", {"id": intent, "outcome": "not-sent-deadline"})
            raise Refused("deadline-after-journal")
        try:
            if self._native:
                self.transport.context={'ledger':str((self.journal.root/'events.jsonl').resolve()),'intent':intent,
                    'operation':operation,'alias':alias,'run':run,'phase':phase}
            if self._native and operation=='invoke':
                self.transport.provenance={'kind':'callback','endpoint':self._endpoints[alias],'alias':alias,'run':None,'action':None}
            status, data, run_id = self.transport.send(method, url, body, min(30, remaining))
            self._observe_clock(deadline)
        except Exception:
            self._frozen = True
            self.append("result", {"id": intent, "outcome": "unknown"})
            raise Refused("request-unknown-no-replay") from None
        outcome = "acknowledged" if 200 <= status < 300 else "refused"
        if write and outcome != "acknowledged":
            self._frozen = True
        self.append("result", {"id": intent, "outcome": outcome, "status": status})
        self._response = (status,data,run_id)
        if outcome == "acknowledged":
            self._completed.add(intent)
            try:
                if operation == "workflow-read":
                    endpoint = strict_json(data)["properties"]["accessEndpoint"]
                    u = urlsplit(endpoint)
                    if (u.scheme != "https" or u.port not in (None, 443) or not u.hostname.endswith(".logic.azure.com")
                            or u.username or u.password or u.query or u.fragment
                            or not re.fullmatch(r"/workflows/[A-Za-z0-9-]{1,128}", u.path)):
                        raise Refused("workflow-endpoint")
                    self._endpoints[alias] = endpoint
                if operation == "callback-read":
                    callback = strict_json(data)["value"]
                    endpoint = urlsplit(self._endpoints[alias])
                    u = urlsplit(callback)
                    q = parse_qs(u.query, strict_parsing=True)
                    if (u.scheme != "https" or u.port not in (None, 443) or u.username or u.password or u.fragment
                            or u.hostname != endpoint.hostname
                            or u.path != endpoint.path + "/triggers/When_a_HTTP_request_is_received/paths/invoke"
                            or set(q) != {"api-version", "sp", "sv", "sig"}
                            or any(len(v) != 1 for v in q.values())
                            or q["api-version"] != ["2016-10-01"]
                            or q["sp"] != ["/triggers/When_a_HTTP_request_is_received/run"]):
                        raise Refused("callback-binding")
                    self._capabilities[alias] = callback
                if operation == "invoke":
                    if run_id is None:
                        raise Refused("missing-provider-run-id")
                    self._record_known_run(alias, run_id)
            except Exception:
                self._frozen = True
                raise Refused("response-contract-incomplete-no-replay") from None
        return {"status": status, "outcome": outcome, "nativeQualified": False,
                "secretBodyRetained": False}

    def _record_known_run(self, alias, run):
        if alias not in ALIASES or type(run) is not str or not RUN.fullmatch(run):
            raise Refused("known-run-shape")
        self.append("known-run", {"alias": alias, "run": run})
        self._known_runs.add((alias, run))

    def _observe_clock(self, deadline):
        now = self.clock()
        if type(now) not in (int, float) or not math.isfinite(now) or now < self._last or now < self._start or now >= deadline:
            self._frozen = True
            raise Refused('immutable-clock')
        self._last = now
        return now

    def close(self):
        self.journal.close()


def live_main(*_args, **_kwargs):
    # Must precede auth, DNS, HTTP, callback acquisition or directory creation.
    raise Refused("live-path-disabled-before-auth")


if __name__ == "__main__":
    raise SystemExit("Live path disabled: offline readiness candidate only.")
