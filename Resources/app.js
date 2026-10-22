const GROUP_COLORS = {
  "木管": "#3d7c85", "铜管": "#c47b32", "打击乐": "#a95545", "弦乐": "#735f91",
  "键盘 / 竖琴": "#9a7e3e", "人声": "#a75270", "其他": "#57756b"
};
const TEMPLATES = {
  orchestration: "",
  pattern: `<h2>Pattern / 华彩</h2><p><strong>形态：</strong></p><p><strong>音域与织体：</strong></p><p><strong>和声功能：</strong></p><p><strong>可以怎样移植：</strong></p>`,
  motif: `<h2>Motif</h2><p><strong>动机轮廓：</strong></p><p><strong>第一次出现：</strong></p><p><strong>后续变形：</strong></p><p><strong>配器如何改变它的意义：</strong></p>`,
  blank: ""
};

let library = { version: 8, scores: {}, order: [], customInstruments: [] };
let currentScoreId = null;
let currentView = "overview";
let editingNoteId = null;
let editingLinks = [];
let editingAnalysis = { melodyText: "", melody: [], chordText: "", chord: [], bassText: "", bass: [], percussionText: "", percussion: [], cadenza: { enabled: false, text: "", instruments: [], description: "", snippets: [] } };
let activeFilter = "全部";
let overviewFilter = "全部";
let scoreRoleFilters = { melody: "", chord: "", bass: "", percussion: "", cadenza: "" };
let overviewRoleFilters = { melody: "", chord: "", bass: "", percussion: "", cadenza: "" };
let scoreMoodFilter = "";
let overviewMoodFilter = "";
let pendingDeletion = null;
let pendingScoreDeletion = null;
let pendingImageTarget = "editor";
let toastTimer = null;

const $ = selector => document.querySelector(selector);
const $$ = selector => [...document.querySelectorAll(selector)];
const bridge = message => {
  if (window.webkit?.messageHandlers?.bridge) window.webkit.messageHandlers.bridge.postMessage(message);
  else if (window.chrome?.webview) window.chrome.webview.postMessage(message);
  else console.log("bridge", message);
};
const escapeHTML = value => String(value ?? "").replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
const clamp = (n, min, max) => Math.max(min, Math.min(max, Number(n) || min));
const uid = prefix => `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2,8)}`;
const currentEntry = () => currentScoreId ? library.scores[currentScoreId] : null;
const currentScore = () => currentEntry()?.score || null;

function persist() {
  rebuildCustomInstruments();
  library.version = 8;
  bridge({ type: "saveLibrary", payload: library });
}

function fileStem(path) {
  return String(path || "").split(/[\\/]/).filter(Boolean).pop()?.replace(/\.(mscz|mscx)$/i, "") || "";
}

function scorePartitionKey(score, fallback = "") {
  const stem = fileStem(score?.path);
  return stem ? `file:${stem.normalize("NFKC").toLocaleLowerCase()}` : String(fallback || score?.id || uid("score"));
}

function findScoreIdForPath(path) {
  const exact = library.order.find(id => library.scores[id]?.score?.path === path);
  if (exact) return exact;
  const candidate = scorePartitionKey({ path }, path);
  return library.scores[candidate] ? candidate : null;
}

function rewriteScoreLinks(oldScoreId, oldPath, newScoreId, newPath, scoreTitle) {
  for (const id of library.order) {
    for (const note of library.scores[id]?.notes || []) {
      for (const link of note.links || []) {
        if (link.scoreId === oldScoreId || (oldPath && link.path === oldPath)) {
          link.scoreId = newScoreId;
          link.path = newPath;
          link.scoreTitle = scoreTitle;
        }
      }
    }
  }
}

function relocateScoreEntry(oldScoreId, replacement) {
  const source = library.scores[oldScoreId];
  if (!source?.score || !replacement?.path) return null;
  const oldPath = source.score.path;
  const customTitle = source.score.customTitle;
  if (customTitle) {
    replacement.customTitle = customTitle;
    replacement.title = customTitle;
  } else {
    replacement.title = fileStem(replacement.path) || replacement.title || source.score.title;
  }
  const newScoreId = scorePartitionKey(replacement, oldScoreId);
  const existingTarget = newScoreId !== oldScoreId ? library.scores[newScoreId] : null;
  const notes = existingTarget
    ? [...(existingTarget.notes || []), ...(source.notes || []).filter(note => !(existingTarget.notes || []).some(other => other.id === note.id))]
    : source.notes || [];
  library.scores[newScoreId] = { score: replacement, notes };
  if (newScoreId !== oldScoreId) delete library.scores[oldScoreId];
  library.order = [...new Set(library.order.map(id => id === oldScoreId ? newScoreId : id))];
  rewriteScoreLinks(oldScoreId, oldPath, newScoreId, replacement.path, replacement.title);
  currentScoreId = newScoreId;
  return newScoreId;
}

function migrateScorePartitions() {
  const migrated = {};
  const order = [];
  const idMap = {};
  const sourceIds = [...new Set([...(library.order || []), ...Object.keys(library.scores || {})])];
  for (const oldId of sourceIds) {
    const entry = library.scores[oldId];
    if (!entry?.score) continue;
    const key = scorePartitionKey(entry.score, oldId);
    idMap[oldId] = key;
    const stem = fileStem(entry.score.path);
    if (stem && !entry.score.customTitle) entry.score.title = stem;
    if (!migrated[key]) {
      migrated[key] = entry;
      order.push(key);
    } else {
      const target = migrated[key];
      const seen = new Set((target.notes || []).map(note => note.id));
      target.notes = [...(target.notes || []), ...(entry.notes || []).filter(note => !seen.has(note.id))];
      if (!target.score.customTitle && entry.score.customTitle) {
        target.score.customTitle = entry.score.customTitle;
        target.score.title = entry.score.customTitle;
      }
      if (entry.score.path) target.score.path = entry.score.path;
    }
  }
  library.scores = migrated;
  library.order = order;
  for (const id of order) {
    for (const note of library.scores[id].notes || []) {
      for (const link of note.links || []) {
        if (idMap[link.scoreId]) link.scoreId = idMap[link.scoreId];
      }
    }
  }
}

function oldOrchestrationSummary(note) {
  const labels = {melody:"主旋律",counter:"副旋律 / 对位",harmony:"和声",bass:"低音",rhythm:"节奏",color:"音色"};
  return Object.entries(note.orchestration || {}).filter(([,v]) => v).map(([k,v]) => `${labels[k] || k}：${v}`).join("；");
}

function normaliseNote(note, score) {
  if (!note.content) {
    const paragraphs = [oldOrchestrationSummary(note), note.instruments, note.body].filter(Boolean);
    note.content = paragraphs.map((p, i) => `${i === 0 && note.orchestration ? "<h2>配器观察</h2>" : ""}<p>${escapeHTML(p)}</p>`).join("");
  }
  if (!Array.isArray(note.links)) {
    note.links = note.start ? [{
      id: uid("link"), path: score.path, scoreId: score.id, scoreTitle: score.title,
      start: note.start, end: note.end || note.start, page: note.page || null,
      snippet: note.image || null
    }] : [];
  }
  note.kind = note.kind === "analysis" ? "analysis" : "free";
  const previous = note.analysis || {};
  note.analysis = {
    melodyText: previous.melodyText || (Array.isArray(previous.melody) ? previous.melody.join(" + ") : ""),
    melody: Array.isArray(previous.melody) ? previous.melody : [],
    chordText: previous.chordText || previous.chordsText || (Array.isArray(previous.chord || previous.chords) ? (previous.chord || previous.chords).join(" + ") : ""),
    chord: Array.isArray(previous.chord || previous.chords) ? (previous.chord || previous.chords) : [],
    bassText: previous.bassText || (Array.isArray(previous.bass) ? previous.bass.join(" + ") : ""),
    bass: Array.isArray(previous.bass) ? previous.bass : [],
    percussionText: previous.percussionText || (Array.isArray(previous.percussion) ? previous.percussion.join(" + ") : ""),
    percussion: Array.isArray(previous.percussion) ? previous.percussion : [],
    cadenza: {
      enabled: !!previous.cadenza?.enabled,
      text: previous.cadenza?.text || (Array.isArray(previous.cadenza?.instruments) ? previous.cadenza.instruments.join(" + ") : ""),
      instruments: Array.isArray(previous.cadenza?.instruments) ? previous.cadenza.instruments : [],
      description: previous.cadenza?.description || "",
      snippets: Array.isArray(previous.cadenza?.snippets) ? previous.cadenza.snippets.filter(Boolean) : (previous.cadenza?.snippet ? [previous.cadenza.snippet] : [])
    }
  };
  note.analysis.melody = parseInstrumentText(note.analysis.melodyText);
  note.analysis.chord = parseInstrumentText(note.analysis.chordText);
  note.analysis.bass = parseInstrumentText(note.analysis.bassText);
  note.analysis.percussion = parseInstrumentText(note.analysis.percussionText);
  note.analysis.cadenza.instruments = parseInstrumentText(note.analysis.cadenza.text);
  note.moodText = String(note.moodText || "");
  note.moodTags = parseExactTags(note.moodText);
  return note;
}

window.receiveLibrary = payload => {
  if (payload?.scores) library = payload;
  library.customInstruments = Array.isArray(library.customInstruments) ? library.customInstruments : [];
  library.order = Array.isArray(library.order) ? library.order.filter(id => library.scores[id]) : [];
  migrateScorePartitions();
  for (const id of library.order) {
    const entry = library.scores[id];
    entry.notes = (entry.notes || []).map(note => normaliseNote(note, entry.score));
  }
  persist();
  renderSidebar();
  showAllNotes();
};

window.receiveScore = score => {
  const scoreId = scorePartitionKey(score, score.id);
  const existing = library.scores[scoreId];
  const previousPath = existing?.score?.path;
  if (existing?.score?.customTitle) {
    score.customTitle = existing.score.customTitle;
    score.title = existing.score.customTitle;
  } else {
    score.title = fileStem(score.path) || score.title || "未命名乐谱";
  }
  library.scores[scoreId] = { score, notes: existing?.notes || [] };
  if (existing && previousPath !== score.path) rewriteScoreLinks(scoreId, previousPath, scoreId, score.path, score.title);
  library.order = [scoreId, ...library.order.filter(id => id !== scoreId)];
  currentScoreId = scoreId;
  currentView = "score";
  persist(); renderSidebar(); renderScore();
  showToast(`已读取 ${score.parts.length} 个乐器、${score.measureCount} 小节`);
};

window.receiveRelocatedScore = payload => {
  const newScoreId = relocateScoreEntry(payload?.scoreId, payload?.score);
  if (!newScoreId) return showToast("无法重新定位这部乐谱");
  persist(); renderSidebar(); renderScore();
  showToast("已更新乐谱位置及全部旧笔记链接");
};

window.receiveScoreScanResults = payload => {
  let repaired = 0;
  for (const match of payload?.matches || []) {
    const entry = library.scores[match.scoreId];
    if (!entry?.score || !match.newPath) continue;
    const oldPath = entry.score.path;
    entry.score.path = match.newPath;
    entry.score.id = match.newPath;
    rewriteScoreLinks(match.scoreId, oldPath, match.scoreId, match.newPath, entry.score.title);
    repaired += 1;
  }
  if (repaired) {
    persist(); renderSidebar();
    if (currentView === "overview") renderAllNotes(); else renderScore();
  }
  const ambiguous = Number(payload?.ambiguous || 0), unmatched = Number(payload?.unmatched || 0);
  if (!Number(payload?.missing || 0)) showToast("所有乐谱路径目前都有效，无需修复");
  else showToast(`已重新定位 ${repaired} 部；${ambiguous} 部重名跳过；${unmatched} 部未找到`);
};

window.receiveMuseScoreSelection = selection => {
  const scoreId = findScoreIdForPath(selection.scorePath) || scorePartitionKey({ path: selection.scorePath }, selection.scorePath);
  if (library.scores[scoreId]) currentScoreId = scoreId;
  currentView = "score";
  renderSidebar(); renderScore();
  const link = {
    id: uid("link"), path: selection.scorePath, scoreId,
    scoreTitle: library.scores[scoreId]?.score?.title || selection.scoreTitle || "MuseScore 乐谱",
    start: Number(selection.startMeasure) || 1,
    end: Number(selection.endMeasure) || Number(selection.startMeasure) || 1,
    startStaff: Number(selection.startStaff) || 0,
    endStaff: Number(selection.endStaff) || Number(selection.staffCount) || 1,
    staffCount: Number(selection.staffCount) || 1,
    snippet: selection.snippet || null
  };
  openNoteDialog(null, null, [link]);
  showToast("已记录 MuseScore 位置；不渲染总谱图片");
};

window.receiveClipboardImage = payload => {
  if (!payload?.dataURL) return showToast("剪贴板里没有图片");
  receiveImageForPendingTarget(payload.dataURL, "粘贴的谱例");
};

window.receiveUploadedImage = payload => {
  if (payload?.error) return showToast(payload.error);
  if (!payload?.dataURL) return showToast("没有读到图片");
  receiveImageForPendingTarget(payload.dataURL, payload.name || "上传的图片");
};

window.setBusy = ({ busy, message }) => {
  $("#busy").classList.toggle("hidden", !busy);
  if (message) $("#busyMessage").textContent = message;
};
window.showToast = ({ message }) => showToast(message);

function showToast(message) {
  const toast = $("#toast");
  toast.textContent = message; toast.classList.add("show");
  clearTimeout(toastTimer); toastTimer = setTimeout(() => toast.classList.remove("show"), 2800);
}

function renderSidebar() {
  const list = $("#scoreList");
  $("#scoreCount").textContent = library.order.length;
  const totalNotes = library.order.reduce((sum, id) => sum + (library.scores[id]?.notes?.length || 0), 0);
  $("#allNoteCount").textContent = totalNotes;
  $("#allNotesButton").classList.toggle("active", currentView === "overview");
  list.innerHTML = library.order.map(id => {
    const entry = library.scores[id], score = entry.score;
    const coverStyle = score.thumbnail ? `style="background-image:url('${score.thumbnail}')"` : "";
    return `<div class="score-row ${currentView === "score" && id === currentScoreId ? "active" : ""}" data-score-row="${escapeHTML(id)}">
      <button class="score-item" data-score-id="${escapeHTML(id)}">
        <span class="mini-cover" ${coverStyle}>${score.thumbnail ? "" : "𝄞"}</span>
        <span><strong>${escapeHTML(score.title)}</strong><small>${score.measureCount} 小节 · ${entry.notes.length} 条笔记</small></span>
      </button>
      <button class="score-remove" data-remove-score="${escapeHTML(id)}" title="从配器手记移除此分区" aria-label="移除 ${escapeHTML(score.title)}">×</button>
    </div>`;
  }).join("");
  $$(".score-item").forEach(button => button.addEventListener("click", () => selectScore(button.dataset.scoreId)));
  $$('[data-remove-score]').forEach(button => button.addEventListener("click", () => askDeleteScore(button.dataset.removeScore)));
}

function selectScore(id) {
  if (!library.scores[id]) return;
  currentScoreId = id; currentView = "score"; renderSidebar(); renderScore();
}

function renderScore() {
  const score = currentScore();
  $("#emptyState").classList.toggle("hidden", !!score || currentView === "overview");
  $("#overviewPage").classList.add("hidden");
  $("#scorePage").classList.toggle("hidden", !score || currentView !== "score");
  if (!score) return;
  $("#scoreTitle").textContent = score.title;
  $("#scoreMeta").textContent = score.composer ? score.composer.toUpperCase() : "MUSESCORE SCORE";
  $("#scoreSubtitle").textContent = score.subtitle || score.path;
  $("#scoreStats").innerHTML = `<span>${score.parts.length} 个乐器 / 声部</span><span>${score.measureCount} 小节</span><span>${score.pageCount || 1} 页</span>`;
  const cover = $("#scoreCover");
  cover.style.backgroundImage = score.thumbnail ? `url('${score.thumbnail}')` : "";
  cover.innerHTML = score.thumbnail ? "" : "<span>𝄞</span>";
  $("#rangeStart").value = 1; $("#rangeEnd").value = Math.min(score.measureCount, 32);
  $("#rangeStart").max = $("#rangeEnd").max = score.measureCount;
  renderTimeline(); renderNotes();
}

function visibleRange() {
  const score = currentScore();
  let start = clamp($("#rangeStart").value, 1, score.measureCount || 1);
  let end = clamp($("#rangeEnd").value, start, score.measureCount || start);
  if (end - start > 95) end = start + 95;
  $("#rangeStart").value = start; $("#rangeEnd").value = end;
  return { start, end, count: end - start + 1 };
}

function renderTimeline() {
  const score = currentScore();
  if (!score) return;
  const { start, end, count } = visibleRange();
  const markersByMeasure = new Map();
  (score.markers || []).forEach(marker => {
    if (!markersByMeasure.has(marker.measure)) markersByMeasure.set(marker.measure, []);
    markersByMeasure.get(marker.measure).push(marker);
  });
  const timeline = $("#timeline"); timeline.style.setProperty("--columns", count);
  let html = `<div class="timeline-row header"><div class="instrument-name">INSTRUMENT / MEASURE</div>`;
  for (let m = start; m <= end; m++) html += `<div class="measure-head ${m % 4 === 1 ? "major" : ""} ${markersByMeasure.has(m) ? "marker" : ""}">${m}</div>`;
  html += `</div><div class="marker-strip"><span>结构标记</span>`;
  for (let m = start; m <= end; m++) html += `<div class="marker">${escapeHTML((markersByMeasure.get(m)||[]).map(x=>x.text).join(" / "))}</div>`;
  html += `</div>`;
  [...new Set(score.parts.map(part => part.group || "其他"))].forEach(group => {
    const parts = score.parts.filter(part => (part.group || "其他") === group);
    html += `<div class="group-row"><span>${escapeHTML(group)}</span><span>${parts.length} parts</span></div>`;
    parts.forEach(part => {
      const map = new Map(part.activities.map(a => [Number(a.measure), a]));
      html += `<div class="timeline-row"><div class="instrument-name" title="${escapeHTML(part.name)}">${escapeHTML(part.shortName || part.name)}</div>`;
      for (let m = start; m <= end; m++) {
        const a = map.get(m), density = a ? Math.max(.18, a.density || .25) : .035;
        const noted = currentEntry().notes.some(n => (n.links || []).some(l => m >= l.start && m <= l.end)) ? " noted" : "";
        html += `<button class="activity-cell${noted}" data-measure="${m}" style="--density:${density};--row-color:${GROUP_COLORS[group] || GROUP_COLORS["其他"]}" title="${escapeHTML(`${part.name} · m.${m}`)}"></button>`;
      }
      html += `</div>`;
    });
  });
  timeline.innerHTML = html;
  $$(".activity-cell").forEach(cell => cell.addEventListener("click", () => openNoteAtMeasure(Number(cell.dataset.measure))));
  $$(".measure-head").forEach(head => head.addEventListener("click", () => openNoteAtMeasure(Number(head.textContent))));
}

function plainText(html) {
  const div = document.createElement("div"); div.innerHTML = html || "";
  return div.textContent.trim();
}

function instrumentBase(name) {
  return String(name || "")
    .trim()
    .replace(/\s*(?:no\.?\s*)?\d+[a-z]?(?:\s*[-–—]\s*\d+[a-z]?)?$/i, "")
    .replace(/\s+[ivx]+$/i, "")
    .replace(/\s+/g, " ") || String(name || "").trim();
}

function rebuildCustomInstruments() {
  const custom = new Map();
  for (const id of library.order || []) {
    const entry = library.scores[id];
    if (!entry) continue;
    const scoreBases = new Set((entry.score?.parts || []).map(part => instrumentBase(part.name || part.shortName).toLocaleLowerCase()));
    for (const note of entry.notes || []) {
      for (const rawName of noteInstruments(note)) {
        const base = instrumentBase(rawName);
        const key = base.toLocaleLowerCase();
        if (base && !scoreBases.has(key) && !custom.has(key)) custom.set(key, base);
      }
    }
  }
  library.customInstruments = [...custom.values()];
}

function parseInstrumentText(text) {
  return [...new Set(String(text || "")
    .split(/[+,，、;；\n|&]+/)
    .map(value => value.trim().replace(/^[•·-]\s*/, ""))
    .filter(Boolean))];
}

function parseExactTags(text) {
  return [...new Set(String(text || "")
    .split(/[,，;；\n]+/)
    .map(value => value.trim())
    .filter(Boolean))];
}

function roleInstruments(note, role) {
  const analysis = note.analysis || {};
  return role === "cadenza" ? (analysis.cadenza?.instruments || []) : (analysis[role] || []);
}

function roleInstrumentOptions(items, role, score = null) {
  const names = [];
  for (const { note } of items) {
    names.push(...roleInstruments(note, role));
  }
  if (score) names.push(...(score.parts || []).map(part => part.name || part.shortName).filter(Boolean));
  names.push(...(library.customInstruments || []));
  return [...new Set(names.map(instrumentBase).filter(Boolean))].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: "base" }));
}

function filterTerms(value) {
  return parseInstrumentText(value).map(instrumentBase).map(value => value.toLocaleLowerCase());
}

function noteInstruments(note) {
  const analysis = note.analysis || {};
  return [...(analysis.melody || []), ...(analysis.chord || []), ...(analysis.bass || []), ...(analysis.percussion || []), ...(analysis.cadenza?.instruments || [])];
}

function matchesRoleFilters(note, filters) {
  return ["melody", "chord", "bass", "percussion", "cadenza"].every(role => {
    const requested = filterTerms(filters[role]);
    if (!requested.length) return true;
    const available = roleInstruments(note, role).map(instrumentBase).map(name => name.toLocaleLowerCase());
    return requested.every(term => available.includes(term));
  });
}

function matchesMoodFilter(note, value) {
  const requested = parseExactTags(value).map(tag => tag.toLocaleLowerCase());
  if (!requested.length) return true;
  const available = (note.moodTags || parseExactTags(note.moodText)).map(tag => tag.toLocaleLowerCase());
  return requested.every(tag => available.includes(tag));
}

function moodBadges(note) {
  return (note.moodTags || parseExactTags(note.moodText)).map(tag => `<span class="mood-badge">${escapeHTML(tag)}</span>`).join("");
}

function cadenzaImages(note) {
  const cadenza = note?.analysis?.cadenza || note?.cadenza || {};
  if (Array.isArray(cadenza.snippets)) return cadenza.snippets.filter(Boolean);
  return cadenza.snippet ? [cadenza.snippet] : [];
}

function scoreFileName(link) {
  const fileName = String(link?.path || "").split("/").filter(Boolean).pop()?.replace(/\.(mscz|mscx)$/i, "");
  return fileName || link?.scoreTitle || "乐谱";
}

function analysisBadges(note) {
  const analysis = note.analysis || {};
  const badges = [];
  if (note.kind === "analysis") badges.push("总谱分析");
  for (const role of ["melody", "chord", "bass", "percussion", "cadenza"]) {
    for (const name of [...new Set(roleInstruments(note, role).map(instrumentBase))]) badges.push(`${role[0].toUpperCase() + role.slice(1)} · ${name}`);
  }
  return badges.map(label => `<span class="analysis-badge">${escapeHTML(label)}</span>`).join("");
}

function analysisPreview(note) {
  const analysis = note.analysis || {};
  const rows = [];
  if (note.kind === "analysis" && analysis.melodyText) rows.push(["Melody", analysis.melodyText]);
  if (note.kind === "analysis" && analysis.chordText) rows.push(["Chord", analysis.chordText]);
  if (note.kind === "analysis" && analysis.bassText) rows.push(["Bass", analysis.bassText]);
  if (note.kind === "analysis" && analysis.percussionText) rows.push(["Percussion", analysis.percussionText]);
  if (analysis.cadenza?.enabled && analysis.cadenza.text) rows.push(["Cadenza", analysis.cadenza.text]);
  return rows.length ? `<div class="analysis-preview">${rows.map(([label, value]) => `<div><b>${label}</b><span>${escapeHTML(value)}</span></div>`).join("")}</div>` : "";
}

function allNotes() {
  return library.order.flatMap(scoreId => {
    const entry = library.scores[scoreId];
    return (entry?.notes || []).map(note => ({ scoreId, score: entry.score, note }));
  }).sort((a, b) => String(b.note.updatedAt || "").localeCompare(String(a.note.updatedAt || "")));
}

function populateRoleDatalists(items, prefix, score = null) {
  for (const role of ["melody", "chord", "bass", "percussion", "cadenza"]) {
    const id = prefix ? `${prefix}${role[0].toUpperCase()}${role.slice(1)}Options` : `${role}Options`;
    $(`#${id}`).innerHTML = roleInstrumentOptions(items, role, score).map(name => `<option value="${escapeHTML(name)}"></option>`).join("");
  }
  const moodId = prefix ? `${prefix}MoodOptions` : "moodOptions";
  const moods = [...new Set(items.flatMap(({ note }) => note.moodTags || parseExactTags(note.moodText)))].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: "base" }));
  $(`#${moodId}`).innerHTML = moods.map(tag => `<option value="${escapeHTML(tag)}"></option>`).join("");
}

function showAllNotes() {
  currentView = "overview";
  $("#emptyState").classList.add("hidden");
  $("#scorePage").classList.add("hidden");
  $("#overviewPage").classList.remove("hidden");
  renderSidebar();
  renderAllNotes();
}

function renderAllNotes() {
  const items = allNotes();
  const query = $("#allNotesSearch").value.trim().toLocaleLowerCase();
  const filters = ["全部", "总谱分析", "普通笔记", "有谱例"];
  $("#allNotesFilters").innerHTML = filters.map(filter => `<button class="filter ${filter === overviewFilter ? "active" : ""}" data-overview-filter="${filter}">${filter}</button>`).join("");
  $$('[data-overview-filter]').forEach(button => button.addEventListener("click", () => { overviewFilter = button.dataset.overviewFilter; renderAllNotes(); }));
  populateRoleDatalists(items, "overview");
  const filtered = items.filter(({ score, note }) => {
    const hasSnippet = cadenzaImages(note).length > 0 || note.links?.some(link => link.snippet);
    if (overviewFilter === "总谱分析" && note.kind !== "analysis") return false;
    if (overviewFilter === "普通笔记" && note.kind === "analysis") return false;
    if (overviewFilter === "有谱例" && !hasSnippet) return false;
    if (!matchesRoleFilters(note, overviewRoleFilters)) return false;
    if (!matchesMoodFilter(note, overviewMoodFilter)) return false;
    if (!query) return true;
    return `${note.title || ""} ${plainText(note.content)} ${score.title || ""} ${(note.links || []).map(link => `${link.scoreTitle || ""} ${scoreFileName(link)}`).join(" ")} ${noteInstruments(note).join(" ")} ${(note.moodTags || []).join(" ")}`.toLocaleLowerCase().includes(query);
  });
  $("#overviewSummary").innerHTML = `<span>${items.length} 条笔记</span><span>${library.order.length} 部乐谱</span><span>${items.filter(item => cadenzaImages(item.note).length || item.note.links?.some(link => link.snippet)).length} 条含谱例</span>`;
  $("#allNotesGrid").innerHTML = filtered.length ? filtered.map(({ scoreId, score, note }) => {
    const firstSnippet = cadenzaImages(note)[0] || note.links?.find(link => link.snippet)?.snippet;
    const routes = (note.links || []).map((link, index) => `<button class="link-chip" data-overview-route="${index}">↗ ${escapeHTML(link.scoreTitle || score.title || "乐谱")} · m.${link.start}${link.end > link.start ? `–${link.end}` : ""}</button>`).join("");
    return `<article class="note-card" data-overview-score="${escapeHTML(scoreId)}" data-overview-note="${escapeHTML(note.id)}">
      ${firstSnippet ? `<img class="snippet-cover" src="${firstSnippet}" alt="乐谱片段">` : ""}
      <div class="body"><button class="score-badge" data-open-score>${escapeHTML(score.title || "未命名乐谱")}</button><h3>${escapeHTML(note.title || "无标题")}</h3><div class="mood-badges">${moodBadges(note)}</div>${analysisPreview(note)}<div class="analysis-badges">${analysisBadges(note)}</div><p>${escapeHTML(plainText(note.content) || (analysisPreview(note) ? "" : "空白笔记"))}</p><div class="route-chips">${routes}</div></div>
      <footer><button data-do="edit">打开笔记</button><button class="delete-card" data-do="delete">删除</button><span></span><small>${new Date(note.updatedAt || Date.now()).toLocaleDateString("zh-CN")}</small></footer>
    </article>`;
  }).join("") : `<div class="empty-notes"><b>${items.length ? "没有匹配的笔记" : "还没有笔记"}</b><p>${items.length ? "换一个关键词或筛选条件试试。" : "先打开一部乐谱，新建空白页；也可以从 MuseScore 选区直接创建。"}</p></div>`;
  $$("[data-overview-note]").forEach(card => {
    const scoreId = card.dataset.overviewScore;
    const note = library.scores[scoreId]?.notes.find(item => item.id === card.dataset.overviewNote);
    if (!note) return;
    card.querySelector('[data-do="edit"]').addEventListener("click", () => openOverviewNote(scoreId, note));
    card.querySelector('[data-do="delete"]').addEventListener("click", () => askDeleteNote(scoreId, note.id));
    card.querySelector('[data-open-score]').addEventListener("click", () => selectScore(scoreId));
    card.querySelectorAll("[data-overview-route]").forEach(button => button.addEventListener("click", () => routeToLink(note.links[Number(button.dataset.overviewRoute)])));
  });
}

function openOverviewNote(scoreId, note) {
  currentScoreId = scoreId;
  renderSidebar();
  openNoteDialog(note);
}

function renderNotes() {
  const entry = currentEntry(); if (!entry) return;
  const filters = ["全部", "总谱分析", "普通笔记", "有谱例"];
  $("#roleFilters").innerHTML = filters.map(f => `<button class="filter ${f === activeFilter ? "active" : ""}" data-filter="${f}">${f}</button>`).join("");
  $$("#roleFilters [data-filter]").forEach(b => b.addEventListener("click", () => { activeFilter = b.dataset.filter; renderNotes(); }));
  const all = [...entry.notes].sort((a,b) => String(b.updatedAt || "").localeCompare(String(a.updatedAt || "")));
  const scoreItems = all.map(note => ({ note }));
  populateRoleDatalists(scoreItems, "", entry.score);
  const notes = all.filter(note => {
    if (activeFilter === "总谱分析" && note.kind !== "analysis") return false;
    if (activeFilter === "普通笔记" && note.kind === "analysis") return false;
    if (activeFilter === "有谱例" && !cadenzaImages(note).length && !note.links?.some(link => link.snippet)) return false;
    return matchesRoleFilters(note, scoreRoleFilters) && matchesMoodFilter(note, scoreMoodFilter);
  });
  $("#noteCount").textContent = all.length;
  $("#noteGrid").innerHTML = notes.length ? notes.map(note => {
    const firstSnippet = cadenzaImages(note)[0] || note.links?.find(l => l.snippet)?.snippet;
    const routes = (note.links || []).map((link, i) => `<button class="link-chip" data-route-index="${i}">↗ ${escapeHTML(link.scoreTitle || "乐谱")} · m.${link.start}${link.end > link.start ? `–${link.end}` : ""}</button>`).join("");
    return `<article class="note-card" data-note-id="${note.id}">
      ${firstSnippet ? `<img class="snippet-cover" src="${firstSnippet}" alt="乐谱片段">` : ""}
      <div class="body"><h3>${escapeHTML(note.title || "无标题")}</h3><div class="mood-badges">${moodBadges(note)}</div>${analysisPreview(note)}<div class="analysis-badges">${analysisBadges(note)}</div><p>${escapeHTML(plainText(note.content) || (analysisPreview(note) ? "" : "空白笔记"))}</p><div class="route-chips">${routes}</div></div>
      <footer><button data-do="edit">打开笔记</button><button class="delete-card" data-do="delete">删除</button><span></span><small>${new Date(note.updatedAt || Date.now()).toLocaleDateString("zh-CN")}</small></footer>
    </article>`;
  }).join("") : `<div class="empty-notes"><b>还没有笔记</b><p>新建空白页，或在 MuseScore 里选择一段后发送到这里。</p></div>`;
  $$(".note-card").forEach(card => {
    const note = entry.notes.find(n => n.id === card.dataset.noteId);
    card.querySelector('[data-do="edit"]').addEventListener("click", () => openNoteDialog(note));
    card.querySelector('[data-do="delete"]').addEventListener("click", () => askDeleteNote(currentScoreId, note.id));
    card.querySelectorAll("[data-route-index]").forEach(button => button.addEventListener("click", () => routeToLink(note.links[Number(button.dataset.routeIndex)])));
  });
}

function makeLinkForMeasure(measure) {
  const score = currentScore();
  return { id: uid("link"), path: score.path, scoreId: score.id, scoreTitle: score.title, start: measure, end: measure, snippet: null };
}

function openNoteAtMeasure(measure) { openNoteDialog(null, null, [makeLinkForMeasure(measure)]); }

function openNoteDialog(note = null, _measure = null, suppliedLinks = null) {
  editingNoteId = note?.id || null;
  editingLinks = structuredClone(suppliedLinks || note?.links || []);
  editingAnalysis = structuredClone(note?.analysis || { melodyText: "", melody: [], chordText: "", chord: [], bassText: "", bass: [], percussionText: "", percussion: [], cadenza: { enabled: false, text: "", instruments: [], description: "", snippets: [] } });
  editingAnalysis.melodyText = editingAnalysis.melodyText || (editingAnalysis.melody || []).join(" + ");
  editingAnalysis.melody = Array.isArray(editingAnalysis.melody) ? editingAnalysis.melody : [];
  editingAnalysis.chordText = editingAnalysis.chordText || editingAnalysis.chordsText || (editingAnalysis.chord || editingAnalysis.chords || []).join(" + ");
  editingAnalysis.chord = Array.isArray(editingAnalysis.chord || editingAnalysis.chords) ? (editingAnalysis.chord || editingAnalysis.chords) : [];
  editingAnalysis.bassText = editingAnalysis.bassText || (editingAnalysis.bass || []).join(" + ");
  editingAnalysis.bass = Array.isArray(editingAnalysis.bass) ? editingAnalysis.bass : [];
  editingAnalysis.percussionText = editingAnalysis.percussionText || (editingAnalysis.percussion || []).join(" + ");
  editingAnalysis.percussion = Array.isArray(editingAnalysis.percussion) ? editingAnalysis.percussion : [];
  editingAnalysis.cadenza = editingAnalysis.cadenza || { enabled: false, text: "", instruments: [], description: "", snippets: [] };
  editingAnalysis.cadenza.text = editingAnalysis.cadenza.text || (editingAnalysis.cadenza.instruments || []).join(" + ");
  editingAnalysis.cadenza.instruments = Array.isArray(editingAnalysis.cadenza.instruments) ? editingAnalysis.cadenza.instruments : [];
  editingAnalysis.cadenza.description = editingAnalysis.cadenza.description || "";
  editingAnalysis.cadenza.snippets = Array.isArray(editingAnalysis.cadenza.snippets) ? editingAnalysis.cadenza.snippets.filter(Boolean) : (editingAnalysis.cadenza.snippet ? [editingAnalysis.cadenza.snippet] : []);
  delete editingAnalysis.cadenza.snippet;
  const noteType = note?.kind === "analysis" ? "analysis" : "free";
  $(`input[name="noteType"][value="${noteType}"]`).checked = true;
  $("#dialogTitle").textContent = note ? "编辑笔记" : "新建笔记";
  const firstLink = editingLinks[0];
  const defaultTitle = firstLink ? `${scoreFileName(firstLink)} · m.${firstLink.start}${firstLink.end > firstLink.start ? `–${firstLink.end}` : ""}` : "";
  $("#noteTitle").value = note?.title || defaultTitle;
  $("#noteEditor").innerHTML = note?.content || "";
  $("#moodText").value = note?.moodText || "";
  $("#melodyText").value = editingAnalysis.melodyText;
  $("#chordText").value = editingAnalysis.chordText;
  $("#bassText").value = editingAnalysis.bassText;
  $("#percussionText").value = editingAnalysis.percussionText;
  $("#cadenzaText").value = editingAnalysis.cadenza.text;
  $("#cadenzaDescription").value = editingAnalysis.cadenza.description;
  $("#templateRow").classList.toggle("hidden", !!note?.content);
  const suggested = editingLinks[0]?.start || 1;
  $("#linkStart").value = suggested; $("#linkEnd").value = editingLinks[0]?.end || suggested;
  $("#linkStart").max = $("#linkEnd").max = currentScore()?.measureCount || 99999;
  $("#deleteNote").classList.toggle("hidden", !note);
  renderAnalysisEditor(); renderEditingLinks(); $("#noteDialog").showModal();
  setTimeout(() => note ? $("#noteEditor").focus() : $("#noteTitle").focus(), 50);
}

function selectedNoteType() {
  return $('input[name="noteType"]:checked')?.value || "free";
}

function syncAnalysisFromFields() {
  for (const role of ["melody", "chord", "bass", "percussion"]) {
    editingAnalysis[`${role}Text`] = $(`#${role}Text`).value.trim();
    editingAnalysis[role] = parseInstrumentText(editingAnalysis[`${role}Text`]);
  }
  editingAnalysis.cadenza.text = $("#cadenzaText").value.trim();
  editingAnalysis.cadenza.instruments = parseInstrumentText(editingAnalysis.cadenza.text);
  editingAnalysis.cadenza.description = $("#cadenzaDescription").value.trim();
}

function renderGeneratedTags() {
  for (const role of ["melody", "chord", "bass", "percussion", "cadenza"]) {
    const names = role === "cadenza" ? editingAnalysis.cadenza.instruments : editingAnalysis[role];
    const tags = [...new Set((names || []).map(instrumentBase).filter(Boolean))];
    $(`#${role}GeneratedTags`).innerHTML = tags.length ? tags.map(tag => `<span>${escapeHTML(tag)}</span>`).join("") : `<em>填写后自动生成筛选标签</em>`;
  }
  const moods = parseExactTags($("#moodText").value);
  $("#moodGeneratedTags").innerHTML = moods.length ? moods.map(tag => `<span>${escapeHTML(tag)}</span>`).join("") : `<em>用逗号分隔描述词</em>`;
}

function renderAnalysisEditor() {
  syncAnalysisFromFields();
  const isAnalysis = selectedNoteType() === "analysis";
  const analysisFields = $("#analysisFields");
  const cadenzaField = $("#cadenzaField");
  analysisFields.classList.toggle("hidden", !isAnalysis);
  if (isAnalysis) {
    analysisFields.append(cadenzaField);
    cadenzaField.classList.add("analysis-part");
    $("#cadenzaToggleTitle").textContent = "Cadenza / Pattern（第 5 部分）";
    $("#cadenzaToggleHint").textContent = "没有华彩时可以不勾选；勾选后填写参与乐器并生成筛选标签。";
  } else {
    $("#scoreLinksEditor").before(cadenzaField);
    cadenzaField.classList.remove("analysis-part");
    $("#cadenzaToggleTitle").textContent = "加入 Cadenza / Pattern（华彩）";
    $("#cadenzaToggleHint").textContent = "可直接填写乐器构成，并自动生成筛选标签。";
  }
  $("#includeCadenza").checked = !!editingAnalysis.cadenza.enabled;
  $("#cadenzaEditor").classList.toggle("hidden", !editingAnalysis.cadenza.enabled);
  const snippets = editingAnalysis.cadenza.snippets || [];
  $("#cadenzaPreview").innerHTML = snippets.length ? snippets.map((src, index) => `<figure><img src="${src}" alt="华彩摘录谱例 ${index + 1}"><button type="button" data-remove-cadenza-image="${index}" aria-label="移除第 ${index + 1} 张华彩图片">×</button><figcaption>华彩图片 ${index + 1}</figcaption></figure>`).join("") : `<span>尚未加入华彩图片；可以连续粘贴或上传多张。</span>`;
  $("#removeCadenzaImage").classList.toggle("hidden", !snippets.length);
  $$('[data-remove-cadenza-image]').forEach(button => button.addEventListener("click", () => {
    editingAnalysis.cadenza.snippets.splice(Number(button.dataset.removeCadenzaImage), 1);
    renderAnalysisEditor();
  }));
  renderGeneratedTags();
}

function renderEditingLinks() {
  $("#scoreLinksEditor").innerHTML = editingLinks.map((link, i) => `<article class="score-link-block" data-link-index="${i}">
    <div><button type="button" class="score-link-route">↗ ${escapeHTML(link.scoreTitle || "乐谱")} · m. ${link.start}${link.end > link.start ? `–${link.end}` : ""}</button><button type="button" class="remove-link" aria-label="移除链接">×</button></div>
    ${link.snippet ? `<img src="${link.snippet}" alt="m. ${link.start}–${link.end} 乐谱片段">` : `<p>只记录乐谱文件与小节位置，不自动渲染图片。</p>`}
  </article>`).join("");
  $$(".score-link-block").forEach(block => {
    const index = Number(block.dataset.linkIndex);
    block.querySelector(".score-link-route").addEventListener("click", () => routeToLink(editingLinks[index]));
    block.querySelector(".remove-link").addEventListener("click", () => { editingLinks.splice(index, 1); renderEditingLinks(); });
  });
}

function sanitiseHTML(html) {
  const doc = new DOMParser().parseFromString(`<div>${html}</div>`, "text/html");
  doc.querySelectorAll("script,style,iframe,object,embed,link,meta").forEach(el => el.remove());
  doc.querySelectorAll("*").forEach(el => [...el.attributes].forEach(attr => {
    if (/^on/i.test(attr.name) || (/^(href|src)$/i.test(attr.name) && /^javascript:/i.test(attr.value))) el.removeAttribute(attr.name);
  }));
  return doc.body.firstElementChild.innerHTML;
}

function markdownFromHTML(html) {
  const root = new DOMParser().parseFromString(`<div>${html || ""}</div>`, "text/html").body.firstElementChild;
  const walk = node => {
    if (node.nodeType === Node.TEXT_NODE) return node.nodeValue || "";
    if (node.nodeType !== Node.ELEMENT_NODE) return "";
    const tag = node.tagName.toLowerCase();
    const inner = () => [...node.childNodes].map(walk).join("");
    if (tag === "br") return "\n";
    if (tag === "h1") return `# ${inner().trim()}\n\n`;
    if (tag === "h2") return `## ${inner().trim()}\n\n`;
    if (tag === "h3") return `### ${inner().trim()}\n\n`;
    if (tag === "p" || tag === "div") return `${inner().trim()}\n\n`;
    if (tag === "strong" || tag === "b") return `**${inner()}**`;
    if (tag === "em" || tag === "i") return `*${inner()}*`;
    if (tag === "blockquote") return inner().trim().split("\n").map(line => `> ${line}`).join("\n") + "\n\n";
    if (tag === "ul") return [...node.children].map(item => `- ${walk(item).trim()}`).join("\n") + "\n\n";
    if (tag === "ol") return [...node.children].map((item, index) => `${index + 1}. ${walk(item).trim()}`).join("\n") + "\n\n";
    if (tag === "li") return inner();
    if (tag === "img") return `![${node.alt || "谱例"}](${node.src})`;
    if (tag === "figcaption") return `\n*${inner().trim()}*`;
    if (tag === "figure") return `${inner().trim()}\n\n`;
    return inner();
  };
  return walk(root).replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
}

function currentNoteExportPayload(format) {
  syncAnalysisFromFields();
  editingAnalysis.cadenza.enabled = $("#includeCadenza").checked;
  const title = $("#noteTitle").value.trim() || "无标题";
  const score = currentScore();
  const mood = $("#moodText").value.trim();
  const contentHTML = sanitiseHTML($("#noteEditor").innerHTML);
  const contentMarkdown = markdownFromHTML(contentHTML);
  const typeLabel = selectedNoteType() === "analysis" ? "总谱分析" : "普通笔记";
  const fields = [
    ["Melody", editingAnalysis.melodyText],
    ["Chord", editingAnalysis.chordText],
    ["Bass", editingAnalysis.bassText],
    ["Percussion", editingAnalysis.percussionText],
    ["Cadenza / Pattern", editingAnalysis.cadenza.enabled ? editingAnalysis.cadenza.text : ""]
  ].filter(([, value]) => value);
  const links = editingLinks.map(link => ({
    scoreTitle: link.scoreTitle || score?.title || "乐谱",
    path: link.path || "",
    start: link.start,
    end: link.end,
    snippet: link.snippet || null
  }));
  const markdown = [
    `# ${title}`,
    "",
    score?.title ? `**乐谱：** ${score.title}` : "",
    `**类型：** ${typeLabel}`,
    mood ? `**Description / Mood：** ${mood}` : "",
    "",
    fields.length ? "## 总谱分析构成" : "",
    ...fields.map(([label, value]) => `- **${label}：** ${value}`),
    fields.length ? "" : "",
    editingAnalysis.cadenza.enabled && editingAnalysis.cadenza.description ? `**华彩说明：** ${editingAnalysis.cadenza.description}\n` : "",
    links.length ? "## 乐谱位置" : "",
    ...links.flatMap(link => {
      const range = link.end > link.start ? `${link.start}-${link.end}` : `${link.start}`;
      const path = String(link.path).replace(/`/g, "\\`");
      return [`- **${link.scoreTitle} · m.${range}**\n  路径：\`${path}\``, link.snippet ? `\n![位置谱例](${link.snippet})` : ""];
    }),
    links.length ? "" : "",
    "## Other notes",
    "",
    contentMarkdown || "（空白）",
    "",
    ...(editingAnalysis.cadenza.enabled ? (editingAnalysis.cadenza.snippets || []).map((src, index) => `![华彩谱例 ${index + 1}](${src})\n`) : [])
  ].filter((line, index, array) => line !== "" || array[index - 1] !== "").join("\n").trim() + "\n";
  const analysisHTML = fields.length ? `<section><h2>总谱分析构成</h2><dl>${fields.map(([label, value]) => `<div><dt>${escapeHTML(label)}</dt><dd>${escapeHTML(value)}</dd></div>`).join("")}</dl>${editingAnalysis.cadenza.enabled && editingAnalysis.cadenza.description ? `<p class="cadenza-description"><b>华彩说明</b><br>${escapeHTML(editingAnalysis.cadenza.description)}</p>` : ""}</section>` : "";
  const linksHTML = links.length ? `<section><h2>乐谱位置</h2>${links.map(link => {
    const range = link.end > link.start ? `${link.start}-${link.end}` : `${link.start}`;
    return `<div class="score-position"><b>${escapeHTML(link.scoreTitle)} · m.${range}</b><code>${escapeHTML(link.path)}</code>${link.snippet ? `<img src="${link.snippet}" alt="位置谱例">` : ""}</div>`;
  }).join("")}</section>` : "";
  const cadenzaHTML = editingAnalysis.cadenza.enabled && editingAnalysis.cadenza.snippets?.length ? `<section><h2>华彩谱例</h2><div class="snippets">${editingAnalysis.cadenza.snippets.map((src, index) => `<figure><img src="${src}" alt="华彩谱例 ${index + 1}"><figcaption>华彩谱例 ${index + 1}</figcaption></figure>`).join("")}</div></section>` : "";
  const html = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><style>
    @page { size: A4; margin: 18mm 17mm 20mm; }
    * { box-sizing:border-box; } body { margin:0; color:#1c302d; font:11pt/1.65 -apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif; }
    header { border-bottom:2px solid #d9673b; padding-bottom:14px; margin-bottom:20px; } h1 { margin:0 0 8px; font:700 26pt/1.2 Georgia,"Songti SC",serif; }
    .meta { color:#61706a; font-size:9.5pt; display:flex; flex-wrap:wrap; gap:6px 18px; } h2 { margin:22px 0 10px; color:#264f49; font:700 15pt/1.3 Georgia,"Songti SC",serif; border-bottom:1px solid #dce1d9; padding-bottom:5px; }
    dl { margin:0; } dl div { display:grid; grid-template-columns:110px 1fr; gap:12px; padding:7px 0; border-bottom:1px solid #eceee8; break-inside:avoid; }
    dt { font-weight:700; color:#47635e; } dd { margin:0; } .score-position { background:#f2f6f2; border-left:3px solid #3a756c; padding:9px 11px; margin:8px 0; break-inside:avoid; }
    code { display:block; margin-top:3px; color:#74807b; font:8pt/1.4 ui-monospace,Menlo,monospace; overflow-wrap:anywhere; } p { margin:7px 0; } blockquote { border-left:3px solid #d9673b; margin:12px 0; padding:3px 12px; color:#5e6c67; }
    ul,ol { padding-left:22px; } figure { margin:14px 0; break-inside:avoid; } img { display:block; max-width:100%; max-height:235mm; object-fit:contain; border:1px solid #e0e3dc; }
    figcaption { color:#7f8984; font-size:8.5pt; margin-top:4px; } .snippets { display:grid; gap:14px; } .cadenza-description { background:#fff7ed; padding:9px 11px; }
    footer { margin-top:28px; padding-top:8px; border-top:1px solid #dce1d9; color:#8a948f; font-size:8pt; }
  </style></head><body><header><h1>${escapeHTML(title)}</h1><div class="meta">${score?.title ? `<span>乐谱：${escapeHTML(score.title)}</span>` : ""}<span>类型：${typeLabel}</span>${mood ? `<span>Description / Mood：${escapeHTML(mood)}</span>` : ""}</div></header>${analysisHTML}${linksHTML}<section><h2>Other notes</h2><div class="note-body">${contentHTML || "<p>（空白）</p>"}</div></section>${cadenzaHTML}<footer>由配器手记导出</footer></body></html>`;
  return { format, title, markdown, html };
}

function exportCurrentNote(format) {
  bridge({ type: "exportNote", payload: currentNoteExportPayload(format) });
}

function saveNote(event) {
  event.preventDefault();
  const entry = currentEntry();
  syncAnalysisFromFields();
  editingAnalysis.cadenza.enabled = $("#includeCadenza").checked;
  const moodText = $("#moodText").value.trim();
  const note = { id: editingNoteId || uid("note"), title: $("#noteTitle").value.trim() || "无标题", kind: selectedNoteType(), moodText, moodTags: parseExactTags(moodText), analysis: editingAnalysis, content: sanitiseHTML($("#noteEditor").innerHTML), links: editingLinks, updatedAt: new Date().toISOString() };
  const index = entry.notes.findIndex(n => n.id === note.id);
  if (index >= 0) entry.notes[index] = note; else entry.notes.push(note);
  persist(); $("#noteDialog").close(); renderSidebar();
  if (currentView === "overview") renderAllNotes();
  else { renderNotes(); renderTimeline(); }
  showToast("笔记已保存");
}

function deleteEditingNote() {
  if (!editingNoteId) return;
  askDeleteNote(currentScoreId, editingNoteId);
}

function askDeleteNote(scoreId, noteId) {
  if (!library.scores[scoreId]?.notes.some(note => note.id === noteId)) return;
  pendingDeletion = { scoreId, noteId };
  $("#deleteConfirmDialog").showModal();
}

function confirmDeleteNote(event) {
  event.preventDefault();
  if (!pendingDeletion) return;
  const { scoreId, noteId } = pendingDeletion;
  library.scores[scoreId].notes = library.scores[scoreId].notes.filter(note => note.id !== noteId);
  pendingDeletion = null;
  persist();
  $("#deleteConfirmDialog").close();
  if ($("#noteDialog").open && editingNoteId === noteId) $("#noteDialog").close();
  renderSidebar();
  if (currentView === "overview") renderAllNotes();
  else { renderNotes(); renderTimeline(); }
  showToast("笔记已删除");
}

function askDeleteScore(scoreId) {
  const entry = library.scores[scoreId];
  if (!entry) return;
  pendingScoreDeletion = scoreId;
  $("#deleteScoreHint").textContent = `“${entry.score.title}”及其中 ${entry.notes.length} 条本地笔记会从配器手记移除；原始 MuseScore 文件不会受到影响。`;
  $("#deleteScoreConfirmDialog").showModal();
}

function confirmDeleteScore(event) {
  event.preventDefault();
  const scoreId = pendingScoreDeletion;
  if (!scoreId || !library.scores[scoreId]) return;
  const title = library.scores[scoreId].score.title;
  delete library.scores[scoreId];
  library.order = library.order.filter(id => id !== scoreId);
  pendingScoreDeletion = null;
  if (currentScoreId === scoreId) currentScoreId = library.order[0] || null;
  persist();
  $("#deleteScoreConfirmDialog").close();
  showAllNotes();
  showToast(`已移除“${title}”分区；原乐谱未删除`);
}

function routeToLink(link) { bridge({ type: "openRoute", payload: { path: link.path, measure: link.start, page: link.page || null } }); }

function receiveImageForPendingTarget(dataURL, alt) {
  if (pendingImageTarget === "cadenza") {
    editingAnalysis.cadenza.snippets = Array.isArray(editingAnalysis.cadenza.snippets) ? editingAnalysis.cadenza.snippets : [];
    editingAnalysis.cadenza.snippets.push(dataURL);
    renderAnalysisEditor();
    showToast(`已加入第 ${editingAnalysis.cadenza.snippets.length} 张华彩图片`);
  } else insertImage(dataURL, alt);
  pendingImageTarget = "editor";
}

function insertImage(dataURL, alt) {
  const editor = $("#noteEditor");
  const markup = `<figure><img src="${dataURL}" alt="${escapeHTML(alt)}"><figcaption>${escapeHTML(alt)}</figcaption></figure><p><br></p>`;
  editor.insertAdjacentHTML("beforeend", markup);
  editor.focus();
  $("#templateRow").classList.add("hidden");
  showToast("图片已插入笔记正文");
}

function openRenameScore() {
  const score = currentScore();
  if (!score) return;
  $("#scoreNameInput").value = score.title || "";
  $("#renameScoreDialog").showModal();
  setTimeout(() => { $("#scoreNameInput").focus(); $("#scoreNameInput").select(); }, 40);
}

function renameCurrentScore(event) {
  event.preventDefault();
  const score = currentScore();
  const name = $("#scoreNameInput").value.trim();
  if (!score || !name) return;
  const oldName = score.title;
  score.title = name;
  score.customTitle = name;
  for (const scoreId of library.order) {
    for (const note of library.scores[scoreId].notes || []) {
      for (const link of note.links || []) {
        if (link.scoreId === score.id || link.path === score.path || link.scoreTitle === oldName) link.scoreTitle = name;
      }
    }
  }
  persist();
  $("#renameScoreDialog").close();
  renderSidebar(); renderScore();
  showToast("乐谱显示名已修改");
}

function switchView(view) {
  $$(".tab").forEach(tab => tab.classList.toggle("active", tab.dataset.view === view));
  $("#mapView").classList.toggle("hidden", view !== "map"); $("#notesView").classList.toggle("hidden", view !== "notes");
  if (view === "notes") renderNotes();
}

$("#captureSelectionButton").addEventListener("click", () => bridge({type:"captureSelection"}));
$("#allNotesButton").addEventListener("click", showAllNotes);
$("#installPluginButton").addEventListener("click", () => bridge({type:"installPlugin"}));
$("#openButton").addEventListener("click", () => bridge({type:"chooseScore"}));
$("#scanLibraryButton").addEventListener("click", () => bridge({
  type: "scanScoreFolder",
  entries: library.order.map(scoreId => ({ scoreId, path: library.scores[scoreId]?.score?.path || "" }))
}));
$$("[data-action='capture']").forEach(button => button.addEventListener("click", () => bridge({type:"captureSelection"})));
$$("[data-action='open']").forEach(button => button.addEventListener("click", () => bridge({type:"chooseScore"})));
$("#newNoteButton").addEventListener("click", () => openNoteDialog());
$("#renameScoreButton").addEventListener("click", openRenameScore);
$("#revealButton").addEventListener("click", () => bridge({type:"revealFile", path: currentScore()?.path}));
$("#relocateScoreButton").addEventListener("click", () => currentScoreId && bridge({
  type: "relocateScore",
  scoreId: currentScoreId,
  oldPath: currentScore()?.path || "",
  scoreTitle: currentScore()?.title || "这部乐谱"
}));
$$(".tab").forEach(tab => tab.addEventListener("click", () => switchView(tab.dataset.view)));
$("#rangeStart").addEventListener("change", renderTimeline); $("#rangeEnd").addEventListener("change", renderTimeline);
$("#noteForm").addEventListener("submit", saveNote); $("#deleteNote").addEventListener("click", deleteEditingNote);
$("#exportMarkdown").addEventListener("click", () => exportCurrentNote("md"));
$("#exportPDF").addEventListener("click", () => exportCurrentNote("pdf"));
$("#deleteConfirmForm").addEventListener("submit", confirmDeleteNote);
$("#deleteConfirmDialog").addEventListener("close", () => { pendingDeletion = null; });
$("#deleteScoreConfirmForm").addEventListener("submit", confirmDeleteScore);
$("#deleteScoreConfirmDialog").addEventListener("close", () => { pendingScoreDeletion = null; });
$("#renameScoreForm").addEventListener("submit", renameCurrentScore);
$$('.dialog-cancel').forEach(button => button.addEventListener("click", () => button.closest("dialog").close("cancel")));
$("#allNotesSearch").addEventListener("input", renderAllNotes);
for (const role of ["melody", "chord", "bass", "percussion", "cadenza"]) {
  $(`#overview${role[0].toUpperCase()}${role.slice(1)}Filter`).addEventListener("input", event => { overviewRoleFilters[role] = event.target.value; renderAllNotes(); });
  $(`#${role}Filter`).addEventListener("input", event => { scoreRoleFilters[role] = event.target.value; renderNotes(); });
}
$("#overviewMoodFilter").addEventListener("input", event => { overviewMoodFilter = event.target.value; renderAllNotes(); });
$("#moodFilter").addEventListener("input", event => { scoreMoodFilter = event.target.value; renderNotes(); });
$$('input[name="noteType"]').forEach(input => input.addEventListener("change", renderAnalysisEditor));
$("#includeCadenza").addEventListener("change", event => { editingAnalysis.cadenza.enabled = event.target.checked; renderAnalysisEditor(); });
for (const role of ["melody", "chord", "bass", "percussion", "cadenza"]) {
  $(`#${role}Text`).addEventListener("input", () => { syncAnalysisFromFields(); renderGeneratedTags(); });
}
$("#moodText").addEventListener("input", renderGeneratedTags);
$("#addScoreLink").addEventListener("click", () => {
  const score = currentScore(), start = clamp($("#linkStart").value, 1, score.measureCount), end = clamp($("#linkEnd").value, start, score.measureCount);
  editingLinks.push({...makeLinkForMeasure(start), end}); renderEditingLinks();
});
$$("[data-template]").forEach(button => button.addEventListener("click", () => {
  if (button.dataset.template === "orchestration") {
    $('input[name="noteType"][value="analysis"]').checked = true;
    renderAnalysisEditor();
  } else if (button.dataset.template === "pattern") {
    editingAnalysis.cadenza.enabled = true;
    renderAnalysisEditor();
  }
  if (!$("#noteEditor").textContent.trim()) $("#noteEditor").innerHTML = TEMPLATES[button.dataset.template];
  $("#templateRow").classList.add("hidden"); $("#noteEditor").focus();
}));
$$(".editor-toolbar [data-command]").forEach(button => button.addEventListener("click", () => {
  $("#noteEditor").focus(); document.execCommand(button.dataset.command, false, button.dataset.value || null);
}));
$("#pasteImage").addEventListener("click", () => { pendingImageTarget = "editor"; bridge({type:"pasteImage"}); });
$("#uploadImage").addEventListener("click", () => { pendingImageTarget = "editor"; bridge({type:"chooseNoteImage"}); });
$("#cadenzaDescription").addEventListener("input", event => { editingAnalysis.cadenza.description = event.target.value; });
$("#pasteCadenzaImage").addEventListener("click", () => { pendingImageTarget = "cadenza"; bridge({type:"pasteImage"}); });
$("#uploadCadenzaImage").addEventListener("click", () => { pendingImageTarget = "cadenza"; bridge({type:"chooseNoteImage"}); });
$("#removeCadenzaImage").addEventListener("click", () => { editingAnalysis.cadenza.snippets = []; renderAnalysisEditor(); });
$("#noteEditor").addEventListener("input", () => $("#templateRow").classList.toggle("hidden", !!$("#noteEditor").textContent.trim()));
window.addEventListener("keydown", event => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "n" && currentScore()) { event.preventDefault(); openNoteDialog(); }
});
