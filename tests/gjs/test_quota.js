import {
    displayPercent,
    formatPercent,
    formatReset,
    formatTime,
    highestPercent,
    paceColor,
    paceLabel,
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
assertEqual(status.onTrackPercent, 50);
assertEqual(status.remainingPercent, 75);
assertEqual(status.window, '5-hour');
assertEqual(paceLabel(status), 'On track');
let color = paceColor(status);
assertEqual(color.green > color.red, true);
color = paceColor({coverage: 0.75, level: 'warning'});
assertEqual(color.red, color.green);
status = quotaStatus(
    {fiveHour: {usedPercent: 60, resetsAt: statusNow + 240 * 60 * 1000}},
    statusNow,
);
assertEqual(status.level, 'warning');
assertEqual(status.onTrackPercent, 20);
assertEqual(paceLabel(status), 'Running high');
color = paceColor(status);
assertEqual(color.red > color.green, true);
status = quotaStatus(
    {fiveHour: {usedPercent: 12, resetsAt: statusNow + 264.12 * 60 * 1000}},
    statusNow,
);
assertEqual(status.onTrackPercent, 12);
assertEqual(status.level, 'normal');
status = quotaStatus(
    {fiveHour: {usedPercent: 12.1, resetsAt: statusNow + 264.12 * 60 * 1000}},
    statusNow,
);
assertEqual(status.level, 'warning');
status = quotaStatus(
    {fiveHour: {usedPercent: 80, resetsAt: statusNow + 240 * 60 * 1000}},
    statusNow,
);
assertEqual(status.level, 'critical');
assertEqual(paceLabel(status), 'At risk');
color = paceColor(status);
assertEqual(color.red > color.green, true);
status = quotaStatus(
    {weekly: {usedPercent: 90, resetsAt: statusNow + 6 * 24 * 60 * 60 * 1000}},
    statusNow,
);
assertEqual(status.level, 'critical');
status = quotaStatus({weekly: {usedPercent: 90, resetsAt: statusNow + 60 * 60 * 1000}}, statusNow);
assertEqual(status.level, 'normal');
assertEqual(status.window, 'weekly');
assertEqual(Math.round(status.onTrackPercent * 10) / 10, 99.4);
status = quotaStatus(
    {
        fiveHour: {usedPercent: 10, resetsAt: null},
        weekly: {usedPercent: 10, resetsAt: statusNow + 3.5 * 24 * 60 * 60 * 1000},
    },
    statusNow,
);
assertEqual(status.window, 'weekly');
assertEqual(status.onTrackPercent, 50);
status = quotaStatus({fiveHour: {usedPercent: 75, resetsAt: null}}, statusNow);
assertEqual(status.level, 'warning');
assertEqual(status.window, '5-hour');
assertEqual(paceLabel(status), 'Pace unavailable');
status = quotaStatus(null, statusNow);
assertEqual(status.level, 'unavailable');
assertEqual(status.onTrackPercent, null);
assertEqual(paceLabel(status), 'Pace unavailable');
assertEqual(paceColor(status), null);
assertEqual(paceColor({coverage: 1, level: 'unavailable'}), null);

const weeklyOnly = parseQuota({
    rateLimits: {
        primary: {usedPercent: 8, windowDurationMins: 10080, resetsAt: 2},
        secondary: null,
    },
});
assertEqual(weeklyOnly.fiveHour, null);
assertEqual(weeklyOnly.weekly.usedPercent, 8);
