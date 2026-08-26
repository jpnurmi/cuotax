import {
    displayPercent,
    formatPercent,
    formatReset,
    formatTime,
    highestPercent,
    parseQuota,
    quotaStatus,
    severity,
} from '../../src/quota.js';

function assertEqual(actual, expected) {
    if (actual !== expected)
        throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

const quota = parseQuota(
    {
        rateLimits: {
            primary: {usedPercent: 99, windowDurationMins: 300, resetsAt: 1},
        },
        rateLimitsByLimitId: {
            codex: {
                primary: {usedPercent: 7, windowDurationMins: 10080, resetsAt: 1788271990},
                secondary: {usedPercent: 42.5, windowDurationMins: 300, resetsAt: 1787699106},
            },
        },
    },
    1234,
);

assertEqual(quota.fiveHour.usedPercent, 42.5);
assertEqual(quota.fiveHour.resetsAt, 1787699106000);
assertEqual(quota.weekly.usedPercent, 7);
assertEqual(quota.weekly.resetsAt, 1788271990000);
assertEqual(quota.updatedAt, 1234);
assertEqual(highestPercent(quota), 42.5);
assertEqual(displayPercent(131), 100);
assertEqual(formatPercent(42.5), '42.5%');
assertEqual(formatPercent(null), '—');
const timestamp = new Date(2026, 7, 26, 9, 5).getTime();
assertEqual(formatTime(timestamp), '09:05');
assertEqual(formatTime(null), '—');
assertEqual(formatReset(timestamp), 'resets 2026-08-26 09:05');
assertEqual(formatReset(null), 'reset unknown');
assertEqual(severity(70), 'warning');
assertEqual(severity(90), 'critical');

const statusNow = new Date(2026, 7, 26, 12).getTime();
let status = quotaStatus(
    {fiveHour: {usedPercent: 25, resetsAt: statusNow + 150 * 60 * 1000}},
    statusNow,
);
assertEqual(status.level, 'normal');
assertEqual(status.remainingPercent, 75);
status = quotaStatus(
    {fiveHour: {usedPercent: 60, resetsAt: statusNow + 240 * 60 * 1000}},
    statusNow,
);
assertEqual(status.level, 'warning');
status = quotaStatus(
    {fiveHour: {usedPercent: 80, resetsAt: statusNow + 240 * 60 * 1000}},
    statusNow,
);
assertEqual(status.level, 'critical');
status = quotaStatus(
    {weekly: {usedPercent: 90, resetsAt: statusNow + 6 * 24 * 60 * 60 * 1000}},
    statusNow,
);
assertEqual(status.level, 'critical');
status = quotaStatus({weekly: {usedPercent: 90, resetsAt: statusNow + 60 * 60 * 1000}}, statusNow);
assertEqual(status.level, 'normal');
assertEqual(quotaStatus(null, statusNow).level, 'unavailable');

const weeklyOnly = parseQuota({
    rateLimits: {
        primary: {usedPercent: 8, windowDurationMins: 10080, resetsAt: 2},
        secondary: null,
    },
});
assertEqual(weeklyOnly.fiveHour, null);
assertEqual(weeklyOnly.weekly.usedPercent, 8);
