import GLib from 'gi://GLib';

import {CodexBackend} from '../extension/backend.js';

const command = GLib.getenv('CODEX_TEST_COMMAND');
if (!command) throw new Error('CODEX_TEST_COMMAND is required');

const loop = new GLib.MainLoop(null, false);
const live = GLib.getenv('CODEX_TEST_LIVE') === '1';
let failure = null;
const backend = new CodexBackend(
    (quota) => {
        try {
            if (!quota.fiveHour && !quota.weekly) throw new Error('Backend returned no quota');
            if (!live && (quota.fiveHour?.usedPercent !== 42 || quota.weekly?.usedPercent !== 7))
                throw new Error('Backend returned the wrong quota');
            if (live) print(JSON.stringify(quota));
        } catch (error) {
            failure = error;
        } finally {
            backend.destroy();
            loop.quit();
        }
    },
    (error) => {
        failure = error;
        backend.destroy();
        loop.quit();
    },
    command,
);

backend.refresh();
loop.run();
if (failure) throw failure;
