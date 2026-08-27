// SPDX-License-Identifier: MIT

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {parseQuota} from './quota.js';

const TIMEOUT_SECONDS = 15;
const RATE_LIMITS_ID = 1;

Gio._promisify(Gio.DataInputStream.prototype, 'read_line_async', 'read_line_finish_utf8');

export class BackendError extends Error {
    constructor(message, diagnostic) {
        super(message);
        this.diagnostic = diagnostic;
    }
}

function executable() {
    const found = GLib.find_program_in_path('codex');
    if (found) return found;

    const home = GLib.get_home_dir();
    const candidates = [
        GLib.build_filenamev([home, '.local', 'bin', 'codex']),
        '/usr/local/bin/codex',
        '/usr/bin/codex',
    ];
    return candidates.find((path) => GLib.file_test(path, GLib.FileTest.IS_EXECUTABLE)) ?? null;
}

function request() {
    return (
        [
            {
                method: 'initialize',
                id: 0,
                params: {
                    clientInfo: {
                        name: 'cuotax',
                        title: 'CuotaX',
                        version: '1',
                    },
                },
            },
            {method: 'initialized', params: {}},
            {method: 'account/rateLimits/read', id: RATE_LIMITS_ID},
        ]
            .map(JSON.stringify)
            .join('\n') + '\n'
    );
}

export class CodexBackend {
    constructor(onSuccess, onError, command = executable()) {
        this._onSuccess = onSuccess;
        this._onError = onError;
        this._command = command;
        this._active = true;
        this._running = false;
        this._queued = false;
        this._process = null;
        this._cancellable = null;
    }

    refresh() {
        if (!this._active) return;
        if (this._running) {
            this._queued = true;
            return;
        }
        this._run();
    }

    async _run() {
        if (!this._command) {
            this._onError(
                new BackendError('Codex CLI not found', 'Install codex on PATH or in ~/.local/bin'),
            );
            return;
        }

        this._running = true;
        this._cancellable = new Gio.Cancellable();
        let timedOut = false;
        let timeoutId = 0;

        try {
            this._process = Gio.Subprocess.new(
                [this._command, 'app-server', '--stdio'],
                Gio.SubprocessFlags.STDIN_PIPE |
                    Gio.SubprocessFlags.STDOUT_PIPE |
                    Gio.SubprocessFlags.STDERR_SILENCE,
            );

            timeoutId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, TIMEOUT_SECONDS, () => {
                timedOut = true;
                timeoutId = 0;
                this._cancellable?.cancel();
                this._process?.force_exit();
                return GLib.SOURCE_REMOVE;
            });

            const writer = new Gio.DataOutputStream({
                base_stream: this._process.get_stdin_pipe(),
            });
            const reader = new Gio.DataInputStream({
                base_stream: this._process.get_stdout_pipe(),
            });
            writer.put_string(request(), this._cancellable);

            while (true) {
                const [line] = await reader.read_line_async(
                    GLib.PRIORITY_DEFAULT,
                    this._cancellable,
                );
                if (line === null)
                    throw new BackendError(
                        'Codex returned no quota',
                        'The app-server connection closed before replying',
                    );

                let message;
                try {
                    message = JSON.parse(line);
                } catch {
                    throw new BackendError(
                        'Codex returned invalid data',
                        'The app-server response was not JSON',
                    );
                }
                if (message.id !== RATE_LIMITS_ID) continue;
                if (message.error) {
                    throw new BackendError(
                        'Codex could not read quota',
                        message.error.message ?? 'Unknown app-server error',
                    );
                }

                const quota = parseQuota(message.result);
                if (this._active) this._onSuccess(quota);
                break;
            }
        } catch (error) {
            if (!this._active) return;
            if (timedOut) {
                this._onError(
                    new BackendError(
                        'Codex quota request timed out',
                        `No response within ${TIMEOUT_SECONDS} seconds`,
                    ),
                );
            } else if (error instanceof BackendError) {
                this._onError(error);
            } else {
                this._onError(
                    new BackendError(
                        'Codex quota request failed',
                        error.message ?? 'The app-server process failed',
                    ),
                );
            }
        } finally {
            if (timeoutId) GLib.source_remove(timeoutId);
            this._process?.force_exit();
            this._process = null;
            this._cancellable = null;
            this._running = false;
            if (this._active && this._queued) {
                this._queued = false;
                this.refresh();
            }
        }
    }

    destroy() {
        this._active = false;
        this._queued = false;
        this._cancellable?.cancel();
        this._process?.force_exit();
        this._process = null;
        this._cancellable = null;
    }
}
