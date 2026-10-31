/* NAS 文件管理 · 原生 JS（上传 / 下载 / 查看，无框架无依赖） */
(function () {
  "use strict";

  var state = {
    path: "/",
    parts: [],
    entries: [],
    rootName: "/",
    maxUploadMb: 0,
    active: 0,
    pending: [],
    uploading: 0,
    rows: 0,
    moreEl: null,
    stats: { ok: 0, fail: 0, skipped: 0 }
  };
  var CONCURRENCY = 2;
  var TEXT_PREVIEW_BYTES = 512 * 1024;
  var MAX_QUEUE_ROWS = 300;   // 队列最多建多少行 DOM，超出只累计不建行
  var MAX_DEPTH = 24;         // 递归文件夹的最大层数（防环）

  var ICONS = {
    dir: "📁", image: "🖼️", video: "🎬", audio: "🎵",
    pdf: "📕", text: "📄", other: "📦"
  };

  var $ = function (id) { return document.getElementById(id); };
  var loginView = $("login-view");
  var appView = $("app-view");
  var rows = $("rows");
  var crumbs = $("crumbs");
  var queueEl = $("queue");
  var emptyEl = $("empty");
  var toastEl = $("toast");
  var dropOverlay = $("drop-overlay");
  var viewer = $("viewer");
  var viewerBody = $("viewer-body");

  /* ------------------------------------------------------------------ 工具 */
  function humanSize(size) {
    var unit = ["B", "KB", "MB", "GB", "TB"];
    var value = Number(size) || 0;
    var index = 0;
    while (value >= 1024 && index < unit.length - 1) { value /= 1024; index += 1; }
    return index === 0 ? value + " B" : value.toFixed(value >= 100 ? 0 : 1) + " " + unit[index];
  }

  function humanTime(seconds) {
    var d = new Date((seconds || 0) * 1000);
    var pad = function (n) { return n < 10 ? "0" + n : "" + n; };
    return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) +
      " " + pad(d.getHours()) + ":" + pad(d.getMinutes());
  }

  function joinPath(base, name) {
    return (base === "/" ? "" : base) + "/" + name;
  }

  function rawUrl(path, download) {
    return "/api/raw?path=" + encodeURIComponent(path) + (download ? "&download=1" : "");
  }

  var toastTimer = null;
  function toast(message, ms) {
    toastEl.textContent = message;
    toastEl.classList.remove("hidden");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.classList.add("hidden"); }, ms || 2600);
  }

  /* ------------------------------------------------------------------ 请求 */
  function api(url, options) {
    var opts = Object.assign({ credentials: "same-origin" }, options || {});
    return fetch(url, opts).then(function (res) {
      return res.json().catch(function () { return null; }).then(function (data) {
        if (res.status === 401) {
          showLogin();
          throw new Error((data && data.error) || "未登录");
        }
        if (!res.ok || !data || data.ok === false) {
          throw new Error((data && data.error) || ("请求失败（HTTP " + res.status + "）"));
        }
        return data;
      });
    });
  }

  /* ------------------------------------------------------------------ 视图切换 */
  function showLogin() {
    appView.classList.add("hidden");
    loginView.classList.remove("hidden");
    closeViewer();
    $("password").value = "";
    $("password").focus();
  }

  function showApp() {
    loginView.classList.add("hidden");
    appView.classList.remove("hidden");
  }

  /* ------------------------------------------------------------------ 登录 */
  $("login-form").addEventListener("submit", function (event) {
    event.preventDefault();
    var button = this.querySelector("button[type=submit]");
    var error = $("login-error");
    error.textContent = "";
    button.disabled = true;
    api("/api/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ password: $("password").value })
    }).then(function () {
      $("password").value = "";
      return refreshSession().then(function () { showApp(); return load("/"); });
    }).catch(function (err) {
      error.textContent = err.message || "登录失败";
    }).then(function () {
      button.disabled = false;
    });
  });

  function refreshSession() {
    return api("/api/session").then(function (data) {
      state.rootName = data.root_name || "/";
      state.maxUploadMb = data.max_upload_mb || 0;
      return data;
    });
  }

  $("btn-logout").addEventListener("click", function () {
    api("/api/logout", { method: "POST" }).catch(function () { /* 忽略 */ })
      .then(function () { showLogin(); toast("已登出"); });
  });

  /* ------------------------------------------------------------------ 目录列表 */
  function load(path) {
    return api("/api/list?path=" + encodeURIComponent(path)).then(function (data) {
      state.path = data.path;
      state.parts = data.parts || [];
      state.entries = data.entries || [];
      render();
    }).catch(function (err) {
      toast(err.message || "加载失败");
    });
  }

  function render() {
    renderCrumbs();
    rows.innerHTML = "";
    emptyEl.classList.toggle("hidden", state.entries.length > 0);
    state.entries.forEach(function (entry) {
      rows.appendChild(renderRow(entry));
    });
    $("btn-up").disabled = state.path === "/";
  }

  function renderCrumbs() {
    crumbs.innerHTML = "";
    var root = document.createElement("button");
    root.type = "button";
    root.className = "crumb" + (state.parts.length === 0 ? " current" : "");
    root.textContent = state.rootName || "/";
    root.addEventListener("click", function () { load("/"); });
    crumbs.appendChild(root);

    var prefix = [];
    state.parts.forEach(function (part) {
      prefix.push(part);
      var sep = document.createElement("span");
      sep.className = "crumb-sep";
      sep.textContent = "/";
      crumbs.appendChild(sep);

      var button = document.createElement("button");
      button.type = "button";
      button.className = "crumb" + (prefix.length === state.parts.length ? " current" : "");
      button.textContent = part;
      var target = "/" + prefix.join("/");
      button.addEventListener("click", function () { load(target); });
      crumbs.appendChild(button);
    });
    crumbs.scrollLeft = crumbs.scrollWidth;
  }

  function renderRow(entry) {
    var tr = document.createElement("tr");

    var tdName = document.createElement("td");
    var cell = document.createElement("div");
    cell.className = "name-cell";
    var icon = document.createElement("span");
    icon.className = "icon-emoji";
    icon.textContent = ICONS[entry.kind] || ICONS.other;
    cell.appendChild(icon);

    var link = document.createElement("button");
    link.type = "button";
    link.className = "name-link" + (entry.is_dir ? " dir" : "");
    link.textContent = entry.name;
    link.title = entry.name;
    link.addEventListener("click", function () {
      if (entry.is_dir) {
        load(joinPath(state.path, entry.name));
      } else {
        openViewer(entry);
      }
    });
    cell.appendChild(link);
    if (entry.is_link) {
      var badge = document.createElement("span");
      badge.className = "badge";
      badge.textContent = "链接";
      cell.appendChild(badge);
    }
    tdName.appendChild(cell);
    tr.appendChild(tdName);

    var tdSize = document.createElement("td");
    tdSize.className = "c-size";
    tdSize.textContent = entry.is_dir ? "—" : humanSize(entry.size);
    tr.appendChild(tdSize);

    var tdTime = document.createElement("td");
    tdTime.className = "c-time";
    tdTime.textContent = humanTime(entry.mtime);
    tr.appendChild(tdTime);

    var tdOps = document.createElement("td");
    tdOps.className = "c-ops";
    if (entry.is_dir) {
      tdOps.appendChild(opButton("进入", function () { load(joinPath(state.path, entry.name)); }));
    } else {
      if (entry.kind !== "other") {
        tdOps.appendChild(opButton("查看", function () { openViewer(entry); }));
      }
      var download = document.createElement("a");
      download.className = "btn link";
      download.href = rawUrl(joinPath(state.path, entry.name), true);
      download.textContent = "下载";
      download.setAttribute("download", entry.name);
      tdOps.appendChild(download);
    }
    tr.appendChild(tdOps);
    return tr;
  }

  function opButton(label, handler) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "btn link";
    button.textContent = label;
    button.addEventListener("click", handler);
    return button;
  }

  $("btn-refresh").addEventListener("click", function () {
    load(state.path).then(function () { toast("已刷新", 1200); });
  });
  $("btn-up").addEventListener("click", function () {
    var parts = state.parts.slice(0, -1);
    load(parts.length ? "/" + parts.join("/") : "/");
  });

  /* ------------------------------------------------------------------ 预览 */
  function openViewer(entry) {
    var path = joinPath(state.path, entry.name);
    var url = rawUrl(path, false);
    $("viewer-title").textContent = entry.name;
    $("viewer-download").href = rawUrl(path, true);
    viewerBody.innerHTML = "";

    if (entry.kind === "image") {
      var img = document.createElement("img");
      img.src = url;
      img.alt = entry.name;
      viewerBody.appendChild(img);
    } else if (entry.kind === "video") {
      var video = document.createElement("video");
      video.src = url;
      video.controls = true;
      video.preload = "metadata";
      viewerBody.appendChild(video);
    } else if (entry.kind === "audio") {
      var audio = document.createElement("audio");
      audio.src = url;
      audio.controls = true;
      viewerBody.appendChild(audio);
    } else if (entry.kind === "pdf") {
      var frame = document.createElement("iframe");
      frame.src = url;
      viewerBody.appendChild(frame);
    } else if (entry.kind === "text") {
      var hint = document.createElement("div");
      hint.className = "viewer-hint";
      hint.textContent = "加载中…";
      viewerBody.appendChild(hint);
      fetch(url, { credentials: "same-origin", headers: { Range: "bytes=0-" + (TEXT_PREVIEW_BYTES - 1) } })
        .then(function (res) { return res.ok || res.status === 206 ? res.text() : Promise.reject(new Error("读取失败")); })
        .then(function (text) {
          viewerBody.innerHTML = "";
          var pre = document.createElement("pre");
          pre.textContent = text || "（空文件）";
          viewerBody.appendChild(pre);
        })
        .catch(function (err) {
          viewerBody.innerHTML = "";
          var fail = document.createElement("div");
          fail.className = "viewer-hint";
          fail.textContent = "无法预览：" + (err.message || "读取失败");
          viewerBody.appendChild(fail);
        });
    } else {
      var note = document.createElement("div");
      note.className = "viewer-hint";
      note.textContent = "该类型无法在线预览，请下载后查看";
      viewerBody.appendChild(note);
    }
    viewer.classList.remove("hidden");
  }

  function closeViewer() {
    viewerBody.innerHTML = "";
    viewer.classList.add("hidden");
  }

  $("viewer-close").addEventListener("click", closeViewer);
  viewer.addEventListener("click", function (event) {
    if (event.target === viewer) { closeViewer(); }
  });
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") { closeViewer(); }
  });

  /* ------------------------------------------------------------------ 上传 */
  $("btn-pick").addEventListener("click", function () { $("file-input").click(); });
  $("file-input").addEventListener("change", function () {
    enqueueItems(pickItems(this.files), state.path);
    this.value = "";
  });
  $("btn-dir").addEventListener("click", function () { $("dir-input").click(); });
  $("dir-input").addEventListener("change", function () {
    enqueueItems(pickItems(this.files), state.path);
    this.value = "";
  });

  var dragDepth = 0;
  window.addEventListener("dragenter", function (event) {
    if (!hasFiles(event)) { return; }
    dragDepth += 1;
    dropOverlay.classList.remove("hidden");
  });
  window.addEventListener("dragover", function (event) {
    if (hasFiles(event)) { event.preventDefault(); }
  });
  window.addEventListener("dragleave", function () {
    dragDepth = Math.max(0, dragDepth - 1);
    if (dragDepth === 0) { dropOverlay.classList.add("hidden"); }
  });
  window.addEventListener("drop", function (event) {
    if (!hasFiles(event)) { return; }
    event.preventDefault();
    dragDepth = 0;
    dropOverlay.classList.add("hidden");
    if (appView.classList.contains("hidden")) { return; }
    var base = state.path;
    collectFromDrop(event.dataTransfer).then(function (items) {
      if (!items.length) {
        toast("没有可上传的文件（空文件夹不会被创建）");
        return;
      }
      enqueueItems(items, base);
    }).catch(function () {
      toast("读取拖入的内容失败，请改用「上传文件夹」按钮");
    });
  });

  function hasFiles(event) {
    return event.dataTransfer && Array.prototype.indexOf.call(event.dataTransfer.types, "Files") >= 0;
  }

  /* 从 FileList 取文件（按钮选文件 / 选文件夹），带出相对目录 */
  function pickItems(fileList) {
    return Array.prototype.map.call(fileList || [], function (file) {
      return { file: file, dir: relativeDir(file.webkitRelativePath || "") };
    });
  }

  /* "照片/2024/a.jpg" -> "照片/2024" */
  function relativeDir(relativePath) {
    var index = relativePath.lastIndexOf("/");
    return index > 0 ? relativePath.slice(0, index) : "";
  }

  /* 拖拽：用 webkitGetAsEntry 递归读出文件夹结构（拿不到就退化成只收文件） */
  function collectFromDrop(dataTransfer) {
    var items = dataTransfer.items;
    var entries = [];
    if (items && items.length) {
      for (var i = 0; i < items.length; i += 1) {
        var entry = items[i].webkitGetAsEntry ? items[i].webkitGetAsEntry() : null;
        if (entry) { entries.push(entry); }
      }
    }
    if (!entries.length) {
      return Promise.resolve(pickItems(dataTransfer.files));
    }
    var out = [];
    var chain = Promise.resolve();
    entries.forEach(function (entry) {
      chain = chain.then(function () { return walkEntry(entry, "", 0, out); });
    });
    return chain.then(function () { return out; });
  }

  function walkEntry(entry, dir, depth, out) {
    if (depth > MAX_DEPTH) { return Promise.resolve(); }
    if (entry.isFile) {
      return new Promise(function (resolve) {
        entry.file(function (file) {
          out.push({ file: file, dir: dir });
          resolve();
        }, function () {
          state.stats.skipped += 1;
          resolve();
        });
      });
    }
    if (entry.isDirectory) {
      var next = dir ? dir + "/" + entry.name : entry.name;
      return readAllEntries(entry.createReader()).then(function (children) {
        var chain = Promise.resolve();
        children.forEach(function (child) {
          chain = chain.then(function () { return walkEntry(child, next, depth + 1, out); });
        });
        return chain;
      });
    }
    return Promise.resolve();
  }

  /* readEntries 每次最多返回 100 项，必须循环读到空数组 */
  function readAllEntries(reader) {
    var all = [];
    function batch() {
      return new Promise(function (resolve, reject) {
        reader.readEntries(resolve, reject);
      }).then(function (items) {
        if (!items.length) { return all; }
        all = all.concat(Array.prototype.slice.call(items));
        return batch();
      });
    }
    return batch();
  }

  function enqueueItems(items, base) {
    if (!items || !items.length) { return; }
    var tasks = items.map(function (item) {
      return createTask(item.file, joinPath(base, item.dir || ""), item.dir || "");
    });
    tasks.forEach(function (task) { state.uploading += 1; });
    tasks.forEach(function (task) {
      if (task.rejectedReason) {
        failTask(task, task.rejectedReason);
        finishTask(task);
      } else {
        state.pending.push(task);
      }
    });
    pump();
  }

  function pump() {
    while (state.active < CONCURRENCY && state.pending.length) {
      runTask(state.pending.shift());
    }
  }

  function createTask(file, target, dir) {
    var label = dir ? dir + "/" + file.name : file.name;
    var el = document.createElement("div");
    el.className = "task";

    var head = document.createElement("div");
    head.className = "task-head";
    var name = document.createElement("span");
    name.className = "task-name";
    name.textContent = label;
    name.title = label;
    var stateText = document.createElement("span");
    stateText.className = "task-state";
    stateText.textContent = "等待";
    var abort = document.createElement("button");
    abort.type = "button";
    abort.className = "btn link";
    abort.textContent = "✕";
    abort.title = "取消";
    head.appendChild(name);
    head.appendChild(stateText);
    head.appendChild(abort);

    var bar = document.createElement("div");
    bar.className = "bar";
    var fill = document.createElement("i");
    bar.appendChild(fill);

    el.appendChild(head);
    el.appendChild(bar);
    if (state.rows < MAX_QUEUE_ROWS) {
      queueEl.appendChild(el);
      state.rows += 1;
    } else if (state.moreEl === null) {
      state.moreEl = document.createElement("div");
      state.moreEl.className = "task more";
      state.moreEl.textContent = "……更多文件在后台排队上传（不在下方逐个显示）";
      queueEl.appendChild(state.moreEl);
    }

    var task = {
      file: file,
      name: file.name,
      el: el,
      fill: fill,
      stateText: stateText,
      abortBtn: abort,
      target: target,
      xhr: null,
      done: false,
      rejected: false
    };

    abort.addEventListener("click", function () {
      if (task.xhr) {
        task.xhr.abort();
      } else if (!task.done) {
        state.pending = state.pending.filter(function (item) { return item !== task; });
        failTask(task, "已取消");
        finishTask(task);
      }
    });

    if (state.maxUploadMb && file.size > state.maxUploadMb * 1024 * 1024) {
      task.rejectedReason = "超过单文件上限 " + state.maxUploadMb + " MB";
    }
    return task;
  }

  function runTask(task) {
    state.active += 1;
    var url = "/api/upload?path=" + encodeURIComponent(task.target) +
      "&name=" + encodeURIComponent(task.name);
    var xhr = new XMLHttpRequest();
    task.xhr = xhr;
    task.stateText.textContent = "0%";

    xhr.open("POST", url, true);
    xhr.setRequestHeader("Content-Type", "application/octet-stream");
    xhr.upload.onprogress = function (event) {
      if (!event.lengthComputable) { return; }
      var percent = Math.min(100, Math.round(event.loaded / event.total * 100));
      task.fill.style.width = percent + "%";
      task.stateText.textContent = percent + "% · " + humanSize(event.loaded);
    };
    xhr.onload = function () {
      state.active = Math.max(0, state.active - 1);
      if (xhr.status === 200) {
        task.done = true;
        state.stats.ok += 1;
        task.fill.style.width = "100%";
        task.stateText.className = "task-state done";
        task.stateText.textContent = "完成 " + humanSize(task.file.size);
        task.el.classList.add("done");
        task.abortBtn.style.display = "none";
        finishTask(task);
      } else {
        var reason = "上传失败（HTTP " + xhr.status + "）";
        try {
          var data = JSON.parse(xhr.responseText);
          if (data && data.error) { reason = data.error; }
        } catch (err) { /* 忽略 */ }
        failTask(task, reason);
        finishTask(task);
      }
      pump();
    };
    xhr.onerror = function () {
      state.active = Math.max(0, state.active - 1);
      failTask(task, "网络错误（连接被中断）");
      finishTask(task);
      pump();
    };
    xhr.onabort = function () {
      state.active = Math.max(0, state.active - 1);
      failTask(task, "已取消");
      finishTask(task);
      pump();
    };
    xhr.send(task.file);
  }

  function failTask(task, reason) {
    if (!task.done) { state.stats.fail += 1; }
    task.done = true;
    task.el.classList.add("fail");
    task.stateText.className = "task-state fail";
    task.stateText.textContent = reason;
    task.abortBtn.style.display = "none";
  }

  function finishTask(task) {
    state.uploading = Math.max(0, state.uploading - 1);
    task.done = true;
    if (state.uploading > 0) { return; }
    var ok = state.stats.ok;
    var failed = state.stats.fail;
    var skipped = state.stats.skipped;
    state.stats = { ok: 0, fail: 0, skipped: 0 };
    if (ok) { load(state.path); }
    var parts = [];
    if (ok) { parts.push("成功 " + ok); }
    if (failed) { parts.push("失败 " + failed); }
    if (skipped) { parts.push("跳过 " + skipped); }
    toast("上传结束：" + (parts.length ? parts.join("，") : "没有文件") +
      (skipped ? "（空文件夹不会被创建）" : ""), 3600);
    setTimeout(function () {
      queueEl.innerHTML = "";
      state.rows = 0;
      state.moreEl = null;
    }, 6000);
  }

  /* ------------------------------------------------------------------ 启动 */
  refreshSession().then(function (data) {
    if (data.authenticated) {
      showApp();
      return load("/");
    }
    showLogin();
    return null;
  }).catch(function () {
    showLogin();
  });
})();
