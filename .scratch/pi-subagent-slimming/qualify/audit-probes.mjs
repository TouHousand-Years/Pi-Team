import { SessionRegistry } from '../../../dist/registry/session.js';
import { RunRegistry } from '../../../dist/registry/run.js';
import { ProcessTable } from '../../../dist/runner/process-table.js';
import { delegate } from '../../../dist/tools/delegate.js';
import { status } from '../../../dist/tools/status.js';
import { collectOutput } from '../../../dist/runner/spawn.js';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { writeFileSync } from 'node:fs';
import assert from 'node:assert/strict';

// Deterministic fake Pi: no model calls, windows or live registry changes.
if (process.argv.includes('-p')) {
  console.log(JSON.stringify({ type: 'session', id: 'audit-session' }));
  setTimeout(() => console.log(JSON.stringify({ type: 'agent_end', messages: [
    { role: 'assistant', content: [{ type: 'text', text: 'audit complete' }] },
  ] })), 400);
} else {
  process.env.PI_BIN = `node ${fileURLToPath(import.meta.url)}`;
  const deps = { sessions: new SessionRegistry(), runs: new RunRegistry(), procs: new ProcessTable() };
  deps.sessions.create({ name: 'existing', piSessionId: 'audit-session', cwd: process.cwd(), goal: 'audit' });
  const first = await delegate({ session: 'existing', prompt: 'first', mode: 'async' }, deps);
  const sessionDuringRun = { ...deps.sessions.get('existing') };
  let second;
  try { second = await delegate({ session: 'existing', prompt: 'second', mode: 'async' }, deps); }
  catch (error) { second = { rejected: error.code }; }
  const running = deps.runs.runningCount();
  let describeCalls = 0;
  const polled = await status({ runId: first.runId, waitTimeoutMs: 0 }, {
    runs: deps.runs,
    transcripts: { usableDir() {}, describe() { describeCalls++; return { available: false, integrity: 'capture-error' }; } },
  });
  await Promise.all(deps.runs.list().map(run => deps.runs.waitForCompletion(run.runId, 3000)));

  // Exit without stdio EOF: grace path destroys an open pipe after 500ms.
  const child = new EventEmitter();
  child.stdout = new PassThrough(); child.stderr = new PassThrough();
  const collected = collectOutput(child);
  child.stdout.write('still open\n');
  child.emit('exit', 0, null);
  const grace = await collected;
  const report = {
    checkedAt: new Date().toISOString(),
    continuationConcurrency: { first: first.status, sessionDuringRun: sessionDuringRun.status, second: second.status ?? second.rejected, running, expected: 'second rejected with session_busy' },
    runningCaptureVisibility: { status: polled.status, hasTranscript: 'transcript' in polled, describeCalls, expected: 'capture failure visible during running' },
    forcedPipeClose: { sawEof: grace.sawEof, expected: false },
  };
  const fixed = process.argv.includes('--fixed');
  if (fixed) {
    assert.equal(sessionDuringRun.status, 'running');
    assert.equal(second.rejected, 'session_busy');
    assert.equal(running, 1);
    assert.equal(polled.transcript?.integrity, 'capture-error');
    assert.equal(describeCalls, 1);
    assert.equal(grace.sawEof, false);
  }
  writeFileSync(new URL(`./_out/${fixed ? 'fix' : 'audit'}-2026-09-18-probes.json`, import.meta.url), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
}
