/* PlexIPTV Dashboard */

let currentPage = 1;
let currentCategory = '';
let currentSearch = '';
let statusInterval = null;
let streamsInterval = null;

// --- API ---

async function api(path, opts = {}) {
    const resp = await fetch('/api' + path, {
        headers: { 'Content-Type': 'application/json', ...opts.headers },
        ...opts,
    });
    return resp.json();
}

// --- Tab Navigation ---

document.querySelectorAll('.nav-link').forEach(link => {
    link.addEventListener('click', e => {
        e.preventDefault();
        const tab = link.dataset.tab;
        document.querySelectorAll('.nav-link').forEach(l => l.classList.remove('active'));
        document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
        link.classList.add('active');
        document.getElementById('tab-' + tab).classList.add('active');

        if (tab === 'status') loadStatus();
        if (tab === 'channels') loadChannels();
        if (tab === 'streams') loadStreams();
        if (tab === 'settings') loadConfig();
    });
});

// --- Status ---

async function loadStatus() {
    try {
        const data = await api('/status');
        const badge = document.getElementById('server-status');
        badge.textContent = 'Online';
        badge.className = 'status-badge online';

        const baseUrl = `http://${data.local_ip}:${data.port}`;
        document.getElementById('tuner-url').textContent = baseUrl;
        document.getElementById('epg-url').textContent = baseUrl + '/xmltv.xml';

        document.getElementById('stats-grid').innerHTML = `
            <div class="stat-card"><div class="label">Tuners</div><div class="value accent">${data.active_streams}/${data.tuner_count}</div></div>
            <div class="stat-card"><div class="label">Total Channels</div><div class="value">${data.total_channels}</div></div>
            <div class="stat-card"><div class="label">Enabled</div><div class="value">${data.enabled_channels}</div></div>
            <div class="stat-card"><div class="label">Uptime</div><div class="value">${formatUptime(data.uptime_seconds)}</div></div>
            <div class="stat-card"><div class="label">Server</div><div class="value" style="font-size:14px">${data.xtream_server}</div></div>
            <div class="stat-card"><div class="label">Local IP</div><div class="value" style="font-size:14px">${data.local_ip}:${data.port}</div></div>
        `;
    } catch {
        document.getElementById('server-status').textContent = 'Offline';
        document.getElementById('server-status').className = 'status-badge offline';
    }
}

function formatUptime(sec) {
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    if (h > 0) return `${h}h ${m}m`;
    return `${m}m`;
}

// --- Channels ---

async function loadCategories() {
    const cats = await api('/categories');
    const select = document.getElementById('category-filter');
    select.innerHTML = '<option value="">All Categories</option>';
    cats.forEach(c => {
        const opt = document.createElement('option');
        opt.value = c.category_id;
        opt.textContent = c.category_name;
        select.appendChild(opt);
    });
}

async function loadChannels(page) {
    if (page !== undefined) currentPage = page;
    const params = new URLSearchParams({ page: currentPage, per_page: 50 });
    if (currentCategory) params.set('category', currentCategory);
    if (currentSearch) params.set('search', currentSearch);

    const data = await api('/channels?' + params);
    document.getElementById('channel-count').textContent = `${data.total} channels`;

    const tbody = document.getElementById('channels-body');
    tbody.innerHTML = data.channels.map(ch => `
        <tr>
            <td>${ch.channel_number || '-'}</td>
            <td>${ch.stream_icon ? `<img class="logo-img" src="${ch.stream_icon}" onerror="this.className='no-logo';this.src=''">` : '<span class="no-logo"></span>'}</td>
            <td>${esc(ch.name)}</td>
            <td style="color:var(--text-dim)">${esc(ch.category_id)}</td>
            <td><span class="epg-badge ${ch.epg_channel_id ? 'yes' : 'no'}">${ch.epg_channel_id ? 'Yes' : 'No'}</span></td>
            <td>
                <label class="toggle">
                    <input type="checkbox" ${ch.enabled ? 'checked' : ''} onchange="toggleChannel(${ch.stream_id})">
                    <span class="slider"></span>
                </label>
            </td>
        </tr>
    `).join('');

    renderPagination(data.page, data.pages);
}

function renderPagination(page, pages) {
    const el = document.getElementById('pagination');
    if (pages <= 1) { el.innerHTML = ''; return; }

    let html = `<button ${page <= 1 ? 'disabled' : ''} onclick="loadChannels(${page - 1})">Prev</button>`;
    html += `<span class="page-info">${page} / ${pages}</span>`;
    html += `<button ${page >= pages ? 'disabled' : ''} onclick="loadChannels(${page + 1})">Next</button>`;
    el.innerHTML = html;
}

async function toggleChannel(streamId) {
    await api(`/channels/${streamId}/toggle`, { method: 'POST' });
}

// Search debounce
let searchTimer;
document.getElementById('channel-search').addEventListener('input', e => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
        currentSearch = e.target.value;
        currentPage = 1;
        loadChannels();
    }, 300);
});

document.getElementById('category-filter').addEventListener('change', e => {
    currentCategory = e.target.value;
    currentPage = 1;
    loadChannels();
});

// --- Streams ---

async function loadStreams() {
    const streams = await api('/streams');
    const el = document.getElementById('streams-list');

    if (!streams.length) {
        el.innerHTML = '<p class="empty-state">No active streams</p>';
        return;
    }

    el.innerHTML = streams.map(s => `
        <div class="stream-card">
            <div class="stream-info">
                <h4><span class="live-dot"></span>${esc(s.channel_name)}</h4>
                <p>Stream #${s.stream_id} &middot; Client: ${s.client_ip}</p>
            </div>
            <div class="stream-meta">
                <div>${formatBytes(s.bytes_sent)}</div>
                <div>${timeSince(s.started_at)}</div>
            </div>
        </div>
    `).join('');
}

// --- Settings ---

async function loadConfig() {
    const cfg = await api('/config');
    const form = document.getElementById('settings-form');
    setField(form, 'xtream.server', cfg.xtream.server);
    setField(form, 'xtream.username', cfg.xtream.username);
    setField(form, 'xtream.password', cfg.xtream.password);
    setField(form, 'tuner.friendly_name', cfg.tuner.friendly_name);
    setField(form, 'tuner.count', cfg.tuner.count);
    setField(form, 'proxy.buffer_size_kb', cfg.proxy.buffer_size_kb);
    setField(form, 'cache.channel_refresh_minutes', cfg.cache.channel_refresh_minutes);
    setField(form, 'cache.epg_refresh_minutes', cfg.cache.epg_refresh_minutes);
}

function setField(form, name, value) {
    const el = form.querySelector(`[name="${name}"]`);
    if (el) el.value = value;
}

document.getElementById('settings-form').addEventListener('submit', async e => {
    e.preventDefault();
    const form = e.target;
    const body = {
        xtream: {
            server: form.querySelector('[name="xtream.server"]').value,
            username: form.querySelector('[name="xtream.username"]').value,
            password: form.querySelector('[name="xtream.password"]').value,
        },
        tuner: {
            friendly_name: form.querySelector('[name="tuner.friendly_name"]').value,
            count: parseInt(form.querySelector('[name="tuner.count"]').value),
        },
        proxy: {
            buffer_size_kb: parseInt(form.querySelector('[name="proxy.buffer_size_kb"]').value),
        },
        cache: {
            channel_refresh_minutes: parseInt(form.querySelector('[name="cache.channel_refresh_minutes"]').value),
            epg_refresh_minutes: parseInt(form.querySelector('[name="cache.epg_refresh_minutes"]').value),
        },
    };

    await api('/config', { method: 'PUT', body: JSON.stringify(body) });
    toast('Settings saved', 'success');
});

// --- Actions ---

async function forceRefresh() {
    toast('Refreshing channels & EPG...', '');
    try {
        const result = await api('/refresh', { method: 'POST' });
        if (result.error) {
            toast('Refresh failed: ' + result.error, 'error');
        } else {
            toast(`Refreshed: ${result.categories} categories, ${result.channels} channels`, 'success');
            loadStatus();
        }
    } catch {
        toast('Refresh failed', 'error');
    }
}

// --- Helpers ---

function esc(str) {
    const d = document.createElement('div');
    d.textContent = str || '';
    return d.innerHTML;
}

function formatBytes(b) {
    if (b < 1024) return b + ' B';
    if (b < 1048576) return (b / 1024).toFixed(1) + ' KB';
    if (b < 1073741824) return (b / 1048576).toFixed(1) + ' MB';
    return (b / 1073741824).toFixed(2) + ' GB';
}

function timeSince(isoStr) {
    const sec = Math.floor((Date.now() - new Date(isoStr).getTime()) / 1000);
    if (sec < 60) return sec + 's';
    if (sec < 3600) return Math.floor(sec / 60) + 'm';
    return Math.floor(sec / 3600) + 'h ' + Math.floor((sec % 3600) / 60) + 'm';
}

function toast(msg, type) {
    const el = document.getElementById('toast');
    el.textContent = msg;
    el.className = 'toast' + (type ? ' ' + type : '');
    setTimeout(() => el.classList.add('hidden'), 3000);
}

// --- Init ---

loadStatus();
loadCategories();

// Auto-refresh status every 10s
statusInterval = setInterval(() => {
    const tab = document.querySelector('.tab.active');
    if (tab && tab.id === 'tab-status') loadStatus();
    if (tab && tab.id === 'tab-streams') loadStreams();
}, 10000);
