/* global TextDecoder, TextEncoder */

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import Soup from 'gi://Soup?version=3.0';

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
        const future = new Date(Date.now() + 60 * 1000).toISOString();
        GLib.file_set_contents(
            cachePath,
            JSON.stringify({
                updatedAt: Date.now(),
                five_hour: {utilization: 98, resets_at: future},
                seven_day: {utilization: 7, resets_at: future},
                limits: [
                    {
                        kind: 'weekly_scoped',
                        percent: 10,
                        resets_at: future,
                        scope: {model: {display_name: 'Fable'}},
                    },
                ],
            }),
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
        const reset = new Date().toISOString();
        for (const usage of [
            {five_hour: {utilization: 98, resets_at: reset}},
            {
                five_hour: {utilization: 98},
                seven_day: {utilization: 7, resets_at: reset},
            },
            {
                five_hour: {utilization: 98},
                limits: [
                    {
                        kind: 'weekly_scoped',
                        percent: 10,
                        resets_at: reset,
                        scope: {model: {display_name: 'Fable'}},
                    },
                ],
            },
        ]) {
            error = null;
            GLib.file_set_contents(cachePath, JSON.stringify({updatedAt: Date.now(), ...usage}));
            await fileBackend.refresh();
            assertEqual(error, httpError);
        }
    } finally {
        fileBackend.destroy();
        Gio.File.new_for_path(cachePath).delete(null);
        Gio.File.new_for_path(credentialsPath).delete(null);
        Gio.File.new_for_path(directory).delete(null);
        if (previousDirectory === null) GLib.unsetenv('CLAUDE_CONFIG_DIR');
        else GLib.setenv('CLAUDE_CONFIG_DIR', previousDirectory, true);
        if (previousToken !== null) GLib.setenv('CLAUDE_CODE_OAUTH_TOKEN', previousToken, true);
    }
    await testRenewal();
}

async function testRenewal() {
    const directory = GLib.dir_make_tmp('cuotax-claude-XXXXXX');
    const previousDirectory = GLib.getenv('CLAUDE_CONFIG_DIR');
    const previousToken = GLib.getenv('CLAUDE_CODE_OAUTH_TOKEN');
    GLib.setenv('CLAUDE_CONFIG_DIR', directory, true);
    GLib.unsetenv('CLAUDE_CODE_OAUTH_TOKEN');
    const file = Gio.File.new_for_path(directory).get_child('.credentials.json');
    const lock = Gio.File.new_for_path(directory).get_child('.oauth_refresh.lock');
    const session = new Soup.Session({timeout: 5});
    const server = new Soup.Server();
    let respond;
    let serverError = null;
    let requests = [];
    let quota = null;
    let error = null;
    const usage = {five_hour: {utilization: 42}};
    const renewed = {
        access_token: 'renewed',
        refresh_token: 'rotated',
        expires_in: 3600,
        scope: 'user:profile user:inference',
    };
    server.add_handler(null, (_server, message, path) => {
        try {
            const request = {
                method: message.get_method(),
                path,
                authorization: message.get_request_headers().get_one('Authorization'),
            };
            if (request.method === 'POST') {
                assertEqual(
                    message.get_request_headers().get_content_type()[0],
                    'application/json',
                );
                request.body = JSON.parse(
                    new TextDecoder().decode(message.get_request_body().flatten().get_data()),
                );
            }
            requests.push(request);
            const response = respond(request);
            message.set_status(response.status ?? 200, null);
            message.set_response(
                'application/json',
                Soup.MemoryUse.COPY,
                new TextEncoder().encode(JSON.stringify(response.data)),
            );
        } catch (failure) {
            serverError = failure;
            message.set_status(500, null);
        }
    });
    server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
    const origin = server.get_uris()[0].to_string();
    const transport = {
        send_and_read_async: async (message, priority, cancellable) => {
            const uri = message.get_uri();
            assertEqual(
                uri.to_string() === 'https://platform.claude.com/v1/oauth/token' ||
                    uri.to_string() === 'https://api.anthropic.com/api/oauth/usage',
                true,
            );
            message.set_uri(GLib.Uri.parse(origin + uri.get_path().slice(1), GLib.UriFlags.NONE));
            return await session.send_and_read_async(message, priority, cancellable);
        },
    };
    const backend = new ClaudeBackend(
        (value) => {
            quota = value;
        },
        (value) => {
            error = value;
        },
        undefined,
        transport,
    );
    function write(oauth = {}, extra = {}) {
        GLib.file_set_contents(
            file.get_path(),
            JSON.stringify({
                ...extra,
                claudeAiOauth: {
                    accessToken: 'fixture',
                    refreshToken: 'refresh',
                    expiresAt: 1,
                    scopes: ['user:profile', 'user:inference'],
                    subscriptionType: 'max',
                    ...oauth,
                },
            }),
        );
    }
    function read() {
        return JSON.parse(new TextDecoder().decode(file.load_contents(null)[1]));
    }
    async function refresh(
        reply = (request) => ({data: request.method === 'POST' ? renewed : usage}),
    ) {
        requests = [];
        quota = null;
        error = null;
        respond = reply;
        await backend.refresh();
        if (serverError) throw serverError;
        assertEqual(lock.query_exists(null), false);
    }
    try {
        write({expiresAt: Date.now() + 3600 * 1000});
        await refresh();
        assertEqual(error, null);
        assertEqual(requests.length, 1);
        assertEqual(requests[0].authorization, 'Bearer fixture');

        write({}, {other: {preserved: true}});
        await refresh();
        assertEqual(error, null);
        assertEqual(quota.fiveHour.usedPercent, 42);
        assertEqual(requests.length, 2);
        assertEqual(requests[0].path, '/v1/oauth/token');
        assertEqual(requests[0].body.grant_type, 'refresh_token');
        assertEqual(requests[0].body.refresh_token, 'refresh');
        assertEqual(requests[0].body.scope, 'user:profile user:inference');
        assertEqual(typeof requests[0].body.client_id, 'string');
        assertEqual(requests[1].authorization, 'Bearer renewed');
        assertEqual(read().claudeAiOauth.refreshToken, 'rotated');
        assertEqual(read().claudeAiOauth.expiresAt > Date.now(), true);
        assertEqual(read().claudeAiOauth.subscriptionType, 'max');
        assertEqual(read().other.preserved, true);
        assertEqual(
            file
                .query_info('unix::mode', Gio.FileQueryInfoFlags.NONE, null)
                .get_attribute_uint32('unix::mode') & 0o777,
            0o600,
        );
        await refresh();
        assertEqual(requests.length, 1);
        assertEqual(requests[0].authorization, 'Bearer renewed');

        write({refreshToken: 'rotated', clientId: 'custom-client'});
        await refresh();
        assertEqual(requests[0].body.refresh_token, 'rotated');
        assertEqual(requests[0].body.client_id, 'custom-client');

        write({expiresAt: Date.now() + 3600 * 1000});
        await refresh((request) => {
            if (request.method === 'POST') return {data: renewed};
            return request.authorization === 'Bearer fixture'
                ? {status: 401, data: {}}
                : {data: usage};
        });
        assertEqual(error, null);
        assertEqual(requests.length, 3);
        assertEqual(requests[2].authorization, 'Bearer renewed');

        write({expiresAt: Date.now() + 3600 * 1000});
        await refresh((request) =>
            request.method === 'POST' ? {data: renewed} : {status: 401, data: {}},
        );
        assertEqual(error.message, 'Claude login expired or unavailable');
        assertEqual(requests.length, 3);

        write();
        const original = JSON.stringify(read());
        await refresh(() => ({status: 400, data: {error: 'invalid_grant'}}));
        assertEqual(error.message, 'Claude login expired or unavailable');
        assertEqual(requests.length, 1);
        assertEqual(JSON.stringify(read()), original);
        await refresh(() => ({status: 503, data: {}}));
        assertEqual(error.message, 'Claude login renewal failed');
        assertEqual(JSON.stringify(read()), original);
        await refresh();
        assertEqual(error, null);

        for (const data of [
            null,
            {},
            {...renewed, expires_in: 0},
            {...renewed, refresh_token: ''},
        ]) {
            write();
            await refresh(() => ({data}));
            assertEqual(error.message, 'Claude login renewal failed');
            assertEqual(read().claudeAiOauth.refreshToken, 'refresh');
        }

        write();
        await refresh((request) => {
            if (request.method === 'POST') {
                write({}, {other: 'changed during renewal'});
                return {data: renewed};
            }
            return {data: usage};
        });
        assertEqual(error, null);
        assertEqual(read().other, 'changed during renewal');
        assertEqual(read().claudeAiOauth.accessToken, 'renewed');

        write();
        await refresh((request) => {
            if (request.method === 'POST') {
                write({accessToken: 'another-login', expiresAt: Date.now() + 3600 * 1000});
                return {data: renewed};
            }
            return {data: usage};
        });
        assertEqual(error, null);
        assertEqual(requests[1].authorization, 'Bearer another-login');
        assertEqual(read().claudeAiOauth.accessToken, 'another-login');

        write();
        lock.make_directory(null);
        lock.set_attribute_uint64(
            'time::modified',
            Math.floor(Date.now() / 1000) - 120,
            Gio.FileQueryInfoFlags.NONE,
            null,
        );
        await refresh();
        assertEqual(error, null);
        assertEqual(read().claudeAiOauth.accessToken, 'renewed');

        write();
        requests = [];
        respond = (request) => ({data: request.method === 'POST' ? renewed : usage});
        const other = new ClaudeBackend(
            () => {},
            (value) => {
                throw value;
            },
            undefined,
            transport,
        );
        try {
            await Promise.all([backend.refresh(), other.refresh()]);
            if (serverError) throw serverError;
            assertEqual(requests.filter((request) => request.method === 'POST').length, 1);
            assertEqual(requests.filter((request) => request.method === 'GET').length, 2);
            assertEqual(lock.query_exists(null), false);
        } finally {
            other.destroy();
        }

        GLib.setenv('CLAUDE_CODE_OAUTH_TOKEN', 'explicit-token', true);
        await refresh(() => ({status: 401, data: {}}));
        assertEqual(requests.length, 1);
        assertEqual(requests[0].authorization, 'Bearer explicit-token');
        GLib.unsetenv('CLAUDE_CODE_OAUTH_TOKEN');

        write();
        backend._session = {
            send_and_read_async: async (message, ...args) => {
                const bytes = await transport.send_and_read_async(message, ...args);
                if (message.get_method() === 'POST') backend.destroy();
                return bytes;
            },
        };
        await refresh();
        assertEqual(quota, null);
        assertEqual(error, null);
        assertEqual(requests.length, 1);
        assertEqual(read().claudeAiOauth.refreshToken, 'rotated');
    } finally {
        backend.destroy();
        session.abort();
        server.disconnect();
        if (lock.query_exists(null)) lock.delete(null);
        if (file.query_exists(null)) file.delete(null);
        Gio.File.new_for_path(directory).delete(null);
        if (previousDirectory === null) GLib.unsetenv('CLAUDE_CONFIG_DIR');
        else GLib.setenv('CLAUDE_CONFIG_DIR', previousDirectory, true);
        if (previousToken === null) GLib.unsetenv('CLAUDE_CODE_OAUTH_TOKEN');
        else GLib.setenv('CLAUDE_CODE_OAUTH_TOKEN', previousToken, true);
    }
}

run()
    .catch((error) => {
        failure = error;
    })
    .finally(() => loop.quit());
loop.run();
if (failure) throw failure;
