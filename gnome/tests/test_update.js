import {hasUpdate} from '../extension/update.js';

function assertEqual(actual, expected) {
    if (actual !== expected)
        throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

assertEqual(hasUpdate('{"ahead_by":2}'), true);
assertEqual(hasUpdate('{"ahead_by":0}'), false);
assertEqual(hasUpdate('{"ahead_by":-1}'), false);
assertEqual(hasUpdate('{"ahead_by":"2"}'), false);
assertEqual(hasUpdate('not json'), false);
