import GLib from 'gi://GLib';
import Gio from 'gi://Gio';

import {BackendError} from '../extension/backend.js';
import {ClaudeBackend, parseToken} from '../extension/claude.js';

function assertEqual(actual, expected) {
    if (actual !== expected) throw new Error(`Expected ${expected}, got ${actual}`);
}

assertEqual(parseToken('{"claudeAiOauth":{"accessToken":"fixture"}}'), 'fixture');
for (const data of ['{}', 'invalid', '{"claudeAiOauth":{"accessToken":"fixture","expiresAt":1}}']) {
    let failed = false;
    try {
        parseToken(data);
    } catch (error) {
        failed = error instanceof BackendError;
    }
    assertEqual(failed, true);
}

const loop = new GLib.MainLoop(null, false);
let failure = null;

async function run() {
    let quota = null;
    let error = null;
    const tokenError = new BackendError('fixture login read', '');
    const backend = new ClaudeBackend(
        (value) => {
            quota = value;
        },
        (value) => {
            error = value;
        },
        async () => {
            throw tokenError;
        },
        {},
        async () => ({fiveHour: {usedPercent: 42}, weekly: null, updatedAt: Date.now()}),
    );
    await backend.refresh();
    assertEqual(quota.fiveHour.usedPercent, 42);
    assertEqual(error, null);
    backend._cache = async () => null;
    await backend.refresh();
    assertEqual(error, tokenError);
    backend.destroy();

    let complete;
    const pending = new Promise((resolve) => {
        complete = resolve;
    });
    const cancelled = new ClaudeBackend(
        () => {
            throw new Error('Destroyed backend returned usage');
        },
        () => {
            throw new Error('Destroyed backend returned an error');
        },
        async () => {
            throw tokenError;
        },
        {},
        () => pending,
    );
    const refresh = cancelled.refresh();
    cancelled.destroy();
    complete({fiveHour: {usedPercent: 42}});
    await refresh;

    const directory = GLib.dir_make_tmp('cuotax-claude-XXXXXX');
    const previousDirectory = GLib.getenv('CLAUDE_CONFIG_DIR');
    const previousToken = GLib.getenv('CLAUDE_CODE_OAUTH_TOKEN');
    GLib.setenv('CLAUDE_CONFIG_DIR', directory, true);
    GLib.unsetenv('CLAUDE_CODE_OAUTH_TOKEN');
    const cachePath = GLib.build_filenamev([directory, 'cuotax-usage.json']);
    const credentialsPath = GLib.build_filenamev([directory, '.credentials.json']);
    const httpError = new BackendError('fixture HTTP request', '');
    const fileBackend = new ClaudeBackend(
        (value) => {
            quota = value;
        },
        (value) => {
            error = value;
        },
        undefined,
        {
            send_and_read_async: async (message) => {
                assertEqual(
                    message.request_headers.get_one('Authorization') === 'Bearer fixture',
                    true,
                );
                throw httpError;
            },
        },
    );
    fileBackend._monitor?.cancel();
    fileBackend._monitor = null;
    fileBackend._watchUsage = () => {};
    try {
        error = null;
        GLib.file_set_contents(
            cachePath,
            JSON.stringify({updatedAt: Date.now(), five_hour: {utilization: 98}}),
        );
        await fileBackend.refresh();
        assertEqual(quota.fiveHour.usedPercent, 98);
        assertEqual(error, null);
        GLib.file_set_contents(
            cachePath,
            JSON.stringify({updatedAt: 1, five_hour: {utilization: 98}}),
        );
        GLib.file_set_contents(credentialsPath, '{"claudeAiOauth":{"accessToken":"fixture"}}');
        await fileBackend.refresh();
        assertEqual(error, httpError);
    } finally {
        fileBackend.destroy();
        Gio.File.new_for_path(cachePath).delete(null);
        Gio.File.new_for_path(credentialsPath).delete(null);
        Gio.File.new_for_path(directory).delete(null);
        if (previousDirectory === null) GLib.unsetenv('CLAUDE_CONFIG_DIR');
        else GLib.setenv('CLAUDE_CONFIG_DIR', previousDirectory, true);
        if (previousToken !== null) GLib.setenv('CLAUDE_CODE_OAUTH_TOKEN', previousToken, true);
    }
}

run()
    .catch((error) => {
        failure = error;
    })
    .finally(() => loop.quit());
loop.run();
if (failure) throw failure;
