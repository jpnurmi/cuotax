// SPDX-License-Identifier: MIT

const FIVE_HOURS_MINUTES = 300;
const WEEK_MINUTES = 7 * 24 * 60;
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function quotaWindow(value) {
    if (!value || !Number.isFinite(value.usedPercent)) return null;

    return {
        usedPercent: value.usedPercent,
        resetsAt: Number.isFinite(value.resetsAt) ? value.resetsAt * 1000 : null,
    };
}

export function parseQuota(result, updatedAt = Date.now()) {
    const limits = result?.rateLimitsByLimitId?.codex ?? result?.rateLimits;
    if (!limits) throw new Error('Codex returned no quota limits');

    let fiveHour = null;
    let weekly = null;
    for (const value of [limits.primary, limits.secondary]) {
        if (value?.windowDurationMins === FIVE_HOURS_MINUTES) fiveHour = quotaWindow(value);
        else if (value?.windowDurationMins === WEEK_MINUTES) weekly = quotaWindow(value);
    }

    if (!fiveHour && !weekly) throw new Error('Codex returned no 5-hour or weekly quota');

    return {fiveHour, weekly, updatedAt};
}

export function highestPercent(quota) {
    const values = [quota?.fiveHour, quota?.weekly]
        .map((value) => value?.usedPercent)
        .filter(Number.isFinite);
    return values.length === 0 ? null : Math.max(...values);
}

export function displayPercent(value) {
    return Number.isFinite(value) ? Math.min(100, Math.max(0, value)) : null;
}

export function formatPercent(value) {
    const displayed = displayPercent(value);
    if (displayed === null) return '—';
    const digits = Number.isInteger(displayed) ? 0 : 1;
    return `${displayed.toFixed(digits)}%`;
}

function dateFrom(value) {
    if (!Number.isFinite(value)) return null;

    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? null : date;
}

function pad(value) {
    return String(value).padStart(2, '0');
}

export function formatTime(value) {
    const date = dateFrom(value);
    if (!date) return '—';

    return `${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function formatRemaining(milliseconds) {
    if (!(milliseconds > 0)) return null;

    const minutes = milliseconds / (60 * 1000);
    if (minutes >= 24 * 60) return `${Math.floor(minutes / (24 * 60))}d`;
    if (minutes >= 60) return `${Math.floor(minutes / 60)}h`;
    return `${Math.max(1, Math.floor(minutes))}m`;
}

export function formatReset(value, now = Date.now()) {
    const date = dateFrom(value);
    if (!date) return 'reset unknown';

    const formatted = `${WEEKDAYS[date.getDay()]}, ${MONTHS[date.getMonth()]} ${date.getDate()}`;
    const remaining = formatRemaining(date.getTime() - now);
    const suffix = remaining ? ` (${remaining})` : '';
    return `${formatted} ${formatTime(value)}${suffix}`;
}

function windowStatus(value, window, durationMinutes, now) {
    if (!value) return null;

    const remainingPercent = 100 - displayPercent(value.usedPercent);
    if (!Number.isFinite(value.resetsAt)) {
        return {
            coverage: remainingPercent / 100,
            level: severity(value.usedPercent),
            onTrackPercent: null,
            remainingPercent,
            window,
        };
    }
    if (value.resetsAt <= now) {
        return {
            coverage: 0,
            level: severity(value.usedPercent),
            onTrackPercent: null,
            remainingPercent,
            window,
        };
    }

    const duration = durationMinutes * 60 * 1000;
    const timeRemaining = Math.min(1, Math.max(0, (value.resetsAt - now) / duration));
    const onTrackPercent = Math.round(1000 * (1 - timeRemaining)) / 10;
    const coverage = timeRemaining === 0 ? Infinity : remainingPercent / 100 / timeRemaining;
    const usedPercent = Math.round(displayPercent(value.usedPercent) * 10) / 10;
    const level =
        usedPercent <= onTrackPercent ? 'normal' : coverage < 0.5 ? 'critical' : 'warning';
    return {coverage, level, onTrackPercent, remainingPercent, window};
}

export function quotaStatus(quota, now = Date.now()) {
    const statuses = [
        windowStatus(quota?.fiveHour, '5-hour', FIVE_HOURS_MINUTES, now),
        windowStatus(quota?.weekly, 'weekly', WEEK_MINUTES, now),
    ].filter(Boolean);
    if (statuses.length === 0)
        return {
            coverage: null,
            level: 'unavailable',
            onTrackPercent: null,
            remainingPercent: null,
            window: null,
        };

    const timed = statuses.filter((status) => status.onTrackPercent !== null);
    const candidates = timed.length > 0 ? timed : statuses;
    const status = candidates.reduce((lowest, current) =>
        current.coverage < lowest.coverage ? current : lowest,
    );
    return {
        coverage: status.coverage,
        level: status.level,
        onTrackPercent: status.onTrackPercent,
        remainingPercent: status.remainingPercent,
        window: status.window,
    };
}

export function paceColor(status) {
    if (status.level === 'unavailable') return null;
    if (!Number.isFinite(status.remainingPercent)) return null;

    const usage = 1 - Math.min(100, Math.max(0, status.remainingPercent)) / 100;
    const threshold = Math.min(1, Math.max(0, (status.onTrackPercent ?? 70) / 100));
    let hue;
    if (usage <= 0) hue = 120;
    else if (usage < threshold) hue = 120 - 90 * smoothstep(usage / threshold);
    else if (usage < 1) hue = 30 * (1 - smoothstep((usage - threshold) / (1 - threshold)));
    else hue = 0;
    const saturation = 0.75;
    const lightness = 0.55;
    const chroma = (1 - Math.abs(2 * lightness - 1)) * saturation;
    const secondary = chroma * (1 - Math.abs(((hue / 60) % 2) - 1));
    const offset = lightness - chroma / 2;
    const [red, green] = hue < 60 ? [chroma, secondary] : [secondary, chroma];
    return {
        red: Math.round((red + offset) * 255),
        green: Math.round((green + offset) * 255),
        blue: Math.round(offset * 255),
        alpha: 255,
    };
}

function smoothstep(value) {
    return value * value * (3 - 2 * value);
}

export function paceLabel(status) {
    if (status.onTrackPercent === null) return 'Pace unavailable';
    if (status.level === 'normal') return 'On track';
    if (status.level === 'warning') return 'Running high';
    if (status.level === 'critical') return 'At risk';
    return 'Pace unavailable';
}

export function severity(value) {
    if (!Number.isFinite(value)) return 'unavailable';
    if (value >= 90) return 'critical';
    if (value >= 70) return 'warning';
    return 'normal';
}
