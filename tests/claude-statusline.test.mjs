import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtemp, readFile, readdir, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import process from 'node:process';
import test from 'node:test';

import {parseClaudeQuota} from '../gnome/extension/quota.js';

async function run(t, input) {
    const directory = await mkdtemp(join(tmpdir(), 'cuotax-statusline-'));
    t.after(() => rm(directory, {recursive: true, force: true}));
    const result = spawnSync(process.execPath, ['scripts/claude-statusline.mjs'], {
        input: typeof input === 'string' ? input : JSON.stringify(input),
        encoding: 'utf8',
        env: {...process.env, CLAUDE_CONFIG_DIR: directory},
    });
    return {directory, result};
}

test('status-line usage is readable by CuotaX', async (t) => {
    const before = Date.now();
    const {directory, result} = await run(t, {
        rate_limits: {
            five_hour: {used_percentage: 42, resets_at: 1_777_000_000},
            seven_day: {used_percentage: 7, resets_at: 1_778_000_000},
        },
        transcript_path: 'private session data',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'Claude 5h 42% · weekly 7%\n');
    const contents = await readFile(join(directory, 'cuotax-usage.json'), 'utf8');
    const usage = JSON.parse(contents);
    assert.ok(usage.updatedAt >= before && usage.updatedAt <= Date.now());
    assert.equal(contents.includes('private session data'), false);
    const quota = parseClaudeQuota(usage, usage.updatedAt);
    assert.equal(quota.fiveHour.usedPercent, 42);
    assert.equal(quota.weekly.usedPercent, 7);
    assert.equal(quota.fiveHour.resetsAt, 1_777_000_000_000);
    assert.deepEqual(await readdir(directory), ['cuotax-usage.json']);
});

test('model-specific limits do not replace the overall weekly quota', async (t) => {
    const {directory, result} = await run(t, {
        rate_limits: {
            limits: [
                {kind: 'weekly_scoped', percent: 99, resets_at: null},
                {kind: 'session', percent: 25, resets_at: '2026-10-12T22:00:00Z'},
                {kind: 'weekly_all', percent: 8, resets_at: '2026-10-19T22:00:00Z'},
            ],
        },
    });
    assert.equal(result.status, 0, result.stderr);
    const usage = JSON.parse(await readFile(join(directory, 'cuotax-usage.json'), 'utf8'));
    assert.equal(parseClaudeQuota(usage).weekly.usedPercent, 8);
});

test('missing subscription usage leaves the cache absent', async (t) => {
    const {directory, result} = await run(t, {rate_limits: null});
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(await readdir(directory), []);
});

test('invalid input leaves the cache absent', async (t) => {
    const {directory, result} = await run(t, 'not JSON');
    assert.equal(result.status, 1);
    assert.deepEqual(await readdir(directory), []);
});

test('Claude usage accepts partial windows and invalid reset dates', () => {
    const quota = parseClaudeQuota({seven_day: {utilization: 8, resets_at: 'invalid'}});
    assert.equal(quota.fiveHour, null);
    assert.equal(quota.weekly.usedPercent, 8);
    assert.equal(quota.weekly.resetsAt, null);
    for (const value of [{}, {five_hour: {utilization: '42'}}, {limits: []}])
        assert.throws(() => parseClaudeQuota(value));
});

test('Fable usage remains separate from the overall weekly quota', async (t) => {
    const reset = '2026-10-20T12:59:59.629512+00:00';
    const limits = [
        {kind: 'weekly_scoped', percent: 99, scope: null},
        {kind: 'weekly_scoped', percent: 80, scope: {model: {display_name: 'Sonnet'}}},
        {kind: 'session', percent: 20, resets_at: reset},
        {kind: 'weekly_all', percent: 5, resets_at: reset},
        {
            kind: 'weekly_scoped',
            percent: 10,
            resets_at: reset,
            scope: {model: {id: null, display_name: 'Fable'}, surface: null},
            private: 'private session data',
        },
    ];
    const direct = parseClaudeQuota({
        five_hour: {utilization: 20},
        seven_day: {utilization: 5},
        limits,
    });
    assert.equal(direct.weekly.usedPercent, 5);
    assert.equal(direct.fable.usedPercent, 10);
    assert.equal(direct.fable.resetsAt, Date.parse(reset));

    const {directory, result} = await run(t, {rate_limits: {limits}});
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'Claude 5h 20% · weekly 5% · Fable weekly 10%\n');
    const contents = await readFile(join(directory, 'cuotax-usage.json'), 'utf8');
    assert.equal(contents.includes('private session data'), false);
    const cached = parseClaudeQuota(JSON.parse(contents));
    assert.equal(cached.weekly.usedPercent, 5);
    assert.deepEqual(cached.fable, direct.fable);
});

test('Fable-only usage is readable by CuotaX', async (t) => {
    const {directory, result} = await run(t, {
        rate_limits: {
            limits: [
                {
                    kind: 'weekly_scoped',
                    percent: 30,
                    resets_at: null,
                    scope: {model: {display_name: 'Fable'}},
                },
            ],
        },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'Claude Fable weekly 30%\n');
    const cached = parseClaudeQuota(
        JSON.parse(await readFile(join(directory, 'cuotax-usage.json'), 'utf8')),
    );
    assert.equal(cached.fiveHour, null);
    assert.equal(cached.weekly, null);
    assert.equal(cached.fable.usedPercent, 30);
    assert.equal(cached.fable.resetsAt, null);
});

test('unavailable Fable usage leaves the overall weekly quota intact', () => {
    for (const limit of [
        {kind: 'weekly_scoped', percent: 20},
        {kind: 'weekly_scoped', percent: 20, scope: {model: null}},
        {kind: 'weekly_scoped', percent: '20', scope: {model: {display_name: 'Fable'}}},
    ]) {
        const quota = parseClaudeQuota({seven_day: {utilization: 5}, limits: [limit]});
        assert.equal(quota.weekly.usedPercent, 5);
        assert.equal(quota.fable, null);
    }
});
