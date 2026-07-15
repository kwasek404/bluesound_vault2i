(function () {
  "use strict";

  var POLL_INTERVAL_MS = 3000;

  var verdictEl = document.getElementById("verdict");
  var connectionNoteEl = document.getElementById("connection-note");
  var vaultStatusEl = document.getElementById("vault-status");
  var pendingFilesEl = document.getElementById("pending-files");
  var pendingAlbumsEl = document.getElementById("pending-albums");
  var updatedAtEl = document.getElementById("updated-at");
  var lastActionEl = document.getElementById("last-action");
  var lastVerifiedEl = document.getElementById("last-verified");
  var lastDeletedEl = document.getElementById("last-deleted");
  var lastDifferEl = document.getElementById("last-differ");
  var lastMissingEl = document.getElementById("last-missing");
  var lastErrorsEl = document.getElementById("last-errors");
  var pendingReindexEl = document.getElementById("pending-reindex");
  var lastReindexEl = document.getElementById("last-reindex");
  var logEl = document.getElementById("log");
  var transferEl = document.getElementById("transfer");
  var transferBarEl = document.getElementById("transfer-bar");
  var transferPercentEl = document.getElementById("transfer-percent");
  var transferPhaseEl = document.getElementById("transfer-phase");
  var transferFileEl = document.getElementById("transfer-file");
  var transferFilesEl = document.getElementById("transfer-files");
  var transferSpeedEl = document.getElementById("transfer-speed");
  var transferEtaEl = document.getElementById("transfer-eta");

  var ACTION_LABELS = {
    skipped_busy: "Vault zajęty - pomijam",
    idle_empty: "Bezczynny - nic do przeniesienia",
    moved: "Przeniesiono",
    partial_retry: "Część plików czeka na ponowną próbę",
    transfer_error: "Błąd transferu - sprawdź log",
    verify_empty: "Brak plików do weryfikacji",
  };

  var TRANSFER_PHASE_LABELS = {
    copy: "Kopiowanie",
    verify: "Weryfikacja",
  };

  function textOrDash(value) {
    if (value === null || value === undefined || value === "") {
      return "-";
    }
    return String(value);
  }

  function textOrBrak(value) {
    if (value === null || value === undefined || value === "") {
      return "brak";
    }
    return String(value);
  }

  function actionLabel(code) {
    if (!code) {
      return textOrBrak(code);
    }
    return ACTION_LABELS[code] || code;
  }

  function boolToTakNie(value) {
    return value ? "tak" : "nie";
  }

  function composeVerdict(status) {
    if (!status || status.state_available === false) {
      return {
        cls: "warn",
        text:
          "Brak danych o stanie - usługa dopiero się uruchamia lub nie wykonała jeszcze przebiegu.",
      };
    }

    if (status.safe_to_power_off === true) {
      return {
        cls: "safe",
        text:
          "BEZPIECZNY DO WYŁĄCZENIA - wszystko przeniesione i zweryfikowane, Vault bezczynny.",
      };
    }

    var blockers = [];
    if (!status.vault_idle) {
      blockers.push("Trwa rip/enkodowanie na Vault.");
    }
    if ((status.pending_music_files || 0) > 0) {
      blockers.push(
        "Pozostało " + status.pending_music_files + " plików do przeniesienia."
      );
    }
    var lastRun = status.last_run || {};
    if ((lastRun.errors || 0) > 0) {
      blockers.push("Błąd ostatniego transferu - sprawdź log.");
    }
    if (status.pending_reindex) {
      blockers.push("Oczekuje reindeks biblioteki.");
    }

    var text = "NIE WYŁĄCZAJ - trwa praca.";
    if (blockers.length > 0) {
      text += " " + blockers.join(" ");
    } else if (status.safe_reason) {
      // Last-resort fallback if structured fields did not produce a reason.
      text += " " + status.safe_reason;
    }

    return { cls: "busy", text: text };
  }

  function vaultStatusText(status) {
    if (status.live_vault_idle === true) {
      return "Bezczynny";
    }
    if (status.live_vault_idle === false) {
      return "Zajęty (rip/enkodowanie)";
    }
    if (status.live_vault_idle === null || status.live_vault_idle === undefined) {
      if (status.vault_idle === true) {
        return "Bezczynny";
      }
      if (status.vault_idle === false) {
        return "Zajęty (rip/enkodowanie)";
      }
      return "Nieznany";
    }
    return "Nieznany";
  }

  function renderStatus(status) {
    var verdict = composeVerdict(status);
    verdictEl.className = "verdict " + verdict.cls;
    verdictEl.textContent = verdict.text;

    vaultStatusEl.textContent = vaultStatusText(status);
    pendingFilesEl.textContent = textOrDash(status.pending_music_files);
    pendingAlbumsEl.textContent = textOrDash(status.pending_music_albums);
    updatedAtEl.textContent = textOrBrak(status.updated_at);

    var lastRun = status.last_run || {};
    lastActionEl.textContent = actionLabel(lastRun.action);
    lastVerifiedEl.textContent = textOrDash(lastRun.verified);
    lastDeletedEl.textContent = textOrDash(lastRun.deleted);
    lastDifferEl.textContent = textOrDash(lastRun.differ);
    lastMissingEl.textContent = textOrDash(lastRun.missing);
    lastErrorsEl.textContent = textOrDash(lastRun.errors);

    pendingReindexEl.textContent = boolToTakNie(status.pending_reindex);
    lastReindexEl.textContent = textOrBrak(status.last_reindex_at);

    renderTransfer(status.transfer);
  }

  function formatSpeed(bytesPerSec) {
    if (!bytesPerSec || bytesPerSec <= 0) {
      return "-";
    }
    if (bytesPerSec >= 1e6) {
      return (bytesPerSec / 1e6).toFixed(1) + " MB/s";
    }
    if (bytesPerSec >= 1e3) {
      return (bytesPerSec / 1e3).toFixed(1) + " KB/s";
    }
    return bytesPerSec.toFixed(0) + " B/s";
  }

  function formatEta(seconds) {
    if (seconds === null || seconds === undefined || seconds < 0) {
      return "-";
    }
    var totalSeconds = Math.floor(seconds);
    var hrs = Math.floor(totalSeconds / 3600);
    var mins = Math.floor((totalSeconds % 3600) / 60);
    var secs = totalSeconds % 60;
    var secsStr = secs < 10 ? "0" + secs : String(secs);
    if (hrs > 0) {
      var minsStr = mins < 10 ? "0" + mins : String(mins);
      return hrs + ":" + minsStr + ":" + secsStr;
    }
    return mins + ":" + secsStr;
  }

  function renderTransfer(transfer) {
    if (!transfer || transfer.active !== true) {
      transferEl.hidden = true;
      return;
    }

    transferEl.hidden = false;

    var percent = transfer.percent;
    if (typeof percent !== "number" || isNaN(percent)) {
      percent = 0;
    }
    percent = Math.max(0, Math.min(100, percent));

    transferBarEl.value = percent;
    transferPercentEl.textContent = percent + "%";
    transferPhaseEl.textContent =
      TRANSFER_PHASE_LABELS[transfer.phase] || textOrDash(transfer.phase);
    transferFileEl.textContent = textOrDash(transfer.current_file);

    if (transfer.files_done === undefined || transfer.files_total === undefined) {
      transferFilesEl.textContent = "-";
    } else {
      transferFilesEl.textContent = transfer.files_done + " / " + transfer.files_total;
    }

    transferSpeedEl.textContent = formatSpeed(transfer.speed);
    transferEtaEl.textContent = formatEta(transfer.eta_seconds);
  }

  function renderLog(logData) {
    var lines = (logData && logData.lines) || [];
    logEl.textContent = lines.join("\n");
  }

  function showConnectionNote(show) {
    connectionNoteEl.hidden = !show;
  }

  function poll() {
    var statusPromise = fetch("/api/status")
      .then(function (r) {
        return r.json();
      })
      .catch(function () {
        return null;
      });

    var logPromise = fetch("/api/log")
      .then(function (r) {
        return r.json();
      })
      .catch(function () {
        return null;
      });

    Promise.all([statusPromise, logPromise]).then(function (results) {
      var status = results[0];
      var log = results[1];

      var anyFailed = status === null || log === null;
      showConnectionNote(anyFailed);

      if (status !== null) {
        renderStatus(status);
      }
      if (log !== null) {
        renderLog(log);
      }
    });
  }

  poll();
  setInterval(poll, POLL_INTERVAL_MS);
})();
