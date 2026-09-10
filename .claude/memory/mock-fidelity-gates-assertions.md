---
name: mock-fidelity-gates-assertions
description: "A stub that answers a query the real tool couldn't answer lets tests pass on impossible states; gate stub responses on the state they depend on"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 5ebed0a1-b9bc-4358-bb30-8917441c08e0
  modified: 2026-09-08T15:33:13.132Z
---

A `claude` CLI stub returned a healthy `plugin details` component inventory for a
plugin whose status was `absent` — a response the real CLI cannot produce, since
a plugin that never installed has no inventory to report. Two boot-path tests
(#944) passed against that impossible state, and the defect only surfaced when a
new test asserted that a hard install failure fails verification: it failed,
correctly, because the stub was handing back success.

**Why:** an unfaithful stub is a silent inversion of [[assertions-must-discriminate]]
— the assertion is right, the fixture makes it unreachable. It reads as green and
survives review, because nothing in the suite contradicts it. This is the mock-side
form of [[fixture-state-hides-vectors]]: the gap was not an untested vector but a
fixture state the production code could never encounter.

**How to apply:** when a stub answers a query whose real answer depends on prior
state, gate the stub on that state (`status != absent` before returning details),
rather than keying only on whether a fixture file exists. Two prompts that catch
it: *could the real tool return this, given what the earlier calls did?* and, for
any capability the stub supports but no test drives, *what would happen if I drove
it?* — an undriven stub branch (here `install_fails`, wired and initialized but
never set) is a reliable place to find one. Discovered via the adversarial pre-PR
review flagging the undriven fixture as low/deferrable; fixing it exposed the
larger fidelity bug underneath, so a low-severity coverage finding is worth
closing rather than deferring when it names an unused fixture.
