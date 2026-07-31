enum PluginRuntimeBootstrap {
    static let source = #"""
    (() => {
      "use strict";

      const nativePost = globalThis.__tenonNativePost;
      delete globalThis.__tenonNativePost;
      delete globalThis.console;

      let phase = "bootstrapping";
      let configuration = null;
      let nextToken = 1;
      let nextTimerHandle = 1;
      let nextProcessHandle = 1;
      let nextWatchHandle = 1;

      const providerHandlers = new Map();
      const providerCalls = new Map();
      const pendingIntents = new Map();
      const pendingLists = new Map();
      const pendingNestedIntents = new Map();
      const pendingStorageWrites = new Map();
      const eventHandlers = new Map();
      const timerHandlers = new Map();
      const processHandlers = new Map();
      const watchHandlers = new Map();
      const viewHandlers = new Map();
      const paletteHandlers = new Map();

      const token = prefix => `${prefix}-${nextToken++}`;
      const clone = (value, seen = new WeakSet(), depth = 0) => {
        if (depth > 64) throw new TypeError("value exceeds the maximum nesting depth");
        if (value === undefined || value === null) return null;
        if (typeof value === "boolean" || typeof value === "string") return value;
        if (typeof value === "number") {
          if (!Number.isFinite(value)) throw new TypeError("numbers must be finite");
          return value;
        }
        if (typeof value !== "object") {
          throw new TypeError(`unsupported value type: ${typeof value}`);
        }
        if (seen.has(value)) throw new TypeError("cyclic values are not supported");
        seen.add(value);
        let owned;
        if (Array.isArray(value)) {
          owned = value.map(item => clone(item, seen, depth + 1));
        } else {
          owned = {};
          for (const [key, item] of Object.entries(value)) {
            owned[key] = clone(item, seen, depth + 1);
          }
        }
        seen.delete(value);
        return owned;
      };
      const post = (topic, payload) => {
        const normalized = payload === undefined ? null : payload;
        nativePost(topic, normalized);
      };
      const deferred = () => {
        let resolve;
        let reject;
        const promise = new Promise((r, j) => {
          resolve = r;
          reject = j;
        });
        return { promise, resolve, reject };
      };
      const cancelledIntentResult = requestID => ({
        ok: false,
        error: {
          code: "tenon.cancelled",
          retryable: false,
          outcome: "unknown"
        },
        meta: { requestID }
      });
      const settleNestedIntentsForCall = (callToken, result) => {
        const state = providerCalls.get(callToken);
        if (!state) return;
        for (const nestedToken of state.nestedTokens) {
          const completion = pendingNestedIntents.get(nestedToken);
          if (!completion || completion.callToken !== callToken) continue;
          pendingNestedIntents.delete(nestedToken);
          completion.resolve(clone(result));
        }
        state.nestedTokens.clear();
      };
      const requireFunction = (value, api) => {
        if (typeof value !== "function") throw new TypeError(`${api} requires a function`);
      };
      const requireString = (value, api) => {
        if (typeof value !== "string" || value.length === 0) {
          throw new TypeError(`${api} requires a non-empty string`);
        }
      };
      const requireUUID = (value, api) => {
        requireString(value, api);
        if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) {
          throw new TypeError(`${api} requires a UUID string`);
        }
      };
      const cleanIntentOptions = value => {
        const source = value && typeof value === "object" ? value : {};
        const result = {};
        if (typeof source.timeoutMs === "number"
            && Number.isFinite(source.timeoutMs)
            && source.timeoutMs > 0) {
          result.timeoutMs = Math.floor(source.timeoutMs);
        }
        if (typeof source.idempotencyKey === "string" && source.idempotencyKey.length > 0) {
          result.idempotencyKey = source.idempotencyKey;
        }
        if (source.target
            && typeof source.target === "object"
            && typeof source.target.providerID === "string"
            && source.target.providerID.length > 0) {
          result.target = { providerID: source.target.providerID };
        }
        if (source.scope && typeof source.scope === "object") {
          if (Object.prototype.hasOwnProperty.call(source.scope, "userGestureID")) {
            throw new TypeError("intent scope userGestureID is host-owned");
          }
          const scope = {};
          if (Object.prototype.hasOwnProperty.call(source.scope, "workspaceID")) {
            requireUUID(source.scope.workspaceID, "intent scope.workspaceID");
            scope.workspaceID = source.scope.workspaceID;
          }
          if (Object.prototype.hasOwnProperty.call(source.scope, "paneID")) {
            requireUUID(source.scope.paneID, "intent scope.paneID");
            scope.paneID = source.scope.paneID;
          }
          if (Object.keys(scope).length > 0) result.scope = scope;
        }
        return result;
      };
      const reportAsyncError = (surface, error) => {
        post("log", {
          message: `${surface}: ${error && error.message ? error.message : String(error)}`
        });
      };
      const invokeAsync = (surface, handler, args) => {
        Promise.resolve()
          .then(() => handler(...args))
          .catch(error => reportAsyncError(surface, error));
      };

      const intents = Object.freeze({
        send(name, input = null, options = {}) {
          requireString(name, "tenon.intents.send");
          const requestToken = token("send");
          const completion = deferred();
          pendingIntents.set(requestToken, completion.resolve);
          post("intent.send", {
            token: requestToken,
            name,
            input: clone(input),
            options: cleanIntentOptions(options)
          });
          return completion.promise;
        },

        handle(name, handler) {
          requireString(name, "tenon.intents.handle");
          requireFunction(handler, "tenon.intents.handle");
          if (phase !== "staging") {
            post("runtime.fatal", {
              reason: `late intent handler binding: ${name}`
            });
            throw new Error(`tenon.intents.handle(${name}) is valid only during staging`);
          }
          if (!configuration.provides.includes(name)) {
            throw new Error(`tenon.intents.handle(${name}) was not declared in manifest.intents.provides`);
          }
          if (providerHandlers.has(name)) {
            throw new Error(`tenon.intents.handle(${name}) was bound more than once`);
          }
          providerHandlers.set(name, handler);
          post("intent.bind", { name });
        },

        list() {
          const requestToken = token("list");
          const completion = deferred();
          pendingLists.set(requestToken, completion.resolve);
          post("intent.list", { token: requestToken });
          return completion.promise;
        }
      });

      const settings = Object.freeze({
        get(key) {
          requireString(key, "tenon.settings.get");
          return clone(Object.prototype.hasOwnProperty.call(configuration.settings, key)
            ? configuration.settings[key]
            : null);
        }
      });

      const storage = Object.freeze({
        get(key) {
          requireString(key, "tenon.storage.get");
          return clone(Object.prototype.hasOwnProperty.call(configuration.storage, key)
            ? configuration.storage[key]
            : null);
        },
        set(key, value) {
          requireString(key, "tenon.storage.set");
          if (phase !== "staging" && phase !== "active") {
            const error = new Error("plugin runtime is stopping");
            error.code = "tenon.provider-retired";
            return Promise.reject(error);
          }
          const owned = clone(value);
          const requestToken = token("storage");
          const completion = deferred();
          pendingStorageWrites.set(requestToken, {
            key,
            value: owned,
            resolve: completion.resolve,
            reject: completion.reject
          });
          post("storage.set", { token: requestToken, key, value: owned });
          return completion.promise;
        }
      });

      const normalizePath = path => {
        requireString(path, "tenon.path");
        const absolute = path.startsWith("/");
        const parts = [];
        for (const part of path.split("/")) {
          if (!part || part === ".") continue;
          if (part === "..") {
            if (parts.length > 0 && parts[parts.length - 1] !== "..") parts.pop();
            else if (!absolute) parts.push(part);
          } else {
            parts.push(part);
          }
        }
        const joined = parts.join("/");
        if (absolute) return `/${joined}` || "/";
        return joined || ".";
      };
      const pathAPI = Object.freeze({
        join(...parts) {
          return normalizePath(parts.filter(part => typeof part === "string" && part.length > 0).join("/"));
        },
        normalize: normalizePath,
        basename(path) {
          const normalized = normalizePath(path);
          if (normalized === "/") return "/";
          return normalized.split("/").pop();
        },
        dirname(path) {
          const normalized = normalizePath(path);
          if (normalized === "/") return "/";
          const parts = normalized.split("/");
          parts.pop();
          if (normalized.startsWith("/")) return parts.join("/") || "/";
          return parts.join("/") || ".";
        },
        extname(path) {
          const name = this.basename(path);
          const index = name.lastIndexOf(".");
          return index <= 0 ? "" : name.slice(index);
        }
      });

      const events = Object.freeze({
        // Publish a fact on a channel this plugin declared in manifest.events.publishes.
        // The name is LOCAL: the host adds the owning prefix, so a plugin cannot name a
        // host channel or another plugin's. There is no reply — a fact that needs one is
        // an intent.
        emit(name, payload = null) {
          requireString(name, "tenon.events.emit");
          post("event.emit", { name, payload: clone(payload) });
        },

        on(name, handler) {
          requireString(name, "tenon.events.on");
          requireFunction(handler, "tenon.events.on");
          const handlers = eventHandlers.get(name) || [];
          const wasEmpty = handlers.length === 0;
          handlers.push(handler);
          eventHandlers.set(name, handlers);
          if (wasEmpty) post("event.bind", { name });
          let active = true;
          return () => {
            if (!active) return;
            active = false;
            const current = eventHandlers.get(name) || [];
            const index = current.indexOf(handler);
            if (index < 0) return;
            const remaining = current.slice();
            remaining.splice(index, 1);
            if (remaining.length === 0) {
              eventHandlers.delete(name);
              post("event.unbind", { name });
            } else {
              eventHandlers.set(name, remaining);
            }
          };
        }
      });

      const timers = Object.freeze({
        after(milliseconds, handler) {
          return scheduleTimer(milliseconds, false, handler, "tenon.timers.after");
        },
        every(milliseconds, handler) {
          return scheduleTimer(milliseconds, true, handler, "tenon.timers.every");
        },
        cancel(handle) {
          timerHandlers.delete(handle);
          post("timer.cancel", { handle });
        }
      });
      const scheduleTimer = (milliseconds, repeats, handler, api) => {
        requireFunction(handler, api);
        if (typeof milliseconds !== "number"
            || !Number.isFinite(milliseconds)
            || milliseconds < 0) {
          throw new TypeError(`${api} requires finite non-negative milliseconds`);
        }
        if (repeats && milliseconds < 10) {
          throw new RangeError(`${api} requires at least 10 milliseconds`);
        }
        const handle = nextTimerHandle++;
        timerHandlers.set(handle, { handler, repeats });
        post("timer.start", { handle, milliseconds, repeats });
        return handle;
      };

      const processAPI = Object.freeze({
        stream(executable, argumentsValue = [], options = {}) {
          requireString(executable, "tenon.process.stream");
          if (!Array.isArray(argumentsValue)
              || !argumentsValue.every(value => typeof value === "string")) {
            throw new TypeError("tenon.process.stream arguments must be strings");
          }
          const source = options && typeof options === "object" ? options : {};
          const handle = nextProcessHandle++;
          processHandlers.set(handle, {
            stdout: typeof source.onStdout === "function" ? source.onStdout : null,
            stderr: typeof source.onStderr === "function" ? source.onStderr : null,
            exit: typeof source.onExit === "function" ? source.onExit : null,
            overflow: typeof source.onOverflow === "function" ? source.onOverflow : null
          });
          const environment = {};
          if (source.env && typeof source.env === "object") {
            for (const [key, value] of Object.entries(source.env)) {
              if (typeof value === "string") environment[key] = value;
            }
          }
          post("process.start", {
            handle,
            executable,
            arguments: argumentsValue,
            cwd: typeof source.cwd === "string" ? source.cwd : null,
            environment
          });
          return Object.freeze({
            handle,
            cancel() {
              processHandlers.delete(handle);
              post("process.cancel", { handle });
            }
          });
        }
      });

      const fs = Object.freeze({
        watch(path, options = {}, handler = null) {
          requireString(path, "tenon.fs.watch");
          if (typeof options === "function") {
            handler = options;
            options = {};
          }
          requireFunction(handler, "tenon.fs.watch");
          const handle = nextWatchHandle++;
          watchHandlers.set(handle, handler);
          post("watch.start", {
            handle,
            path,
            recursive: options && options.recursive === true
          });
          return Object.freeze({
            handle,
            cancel() {
              watchHandlers.delete(handle);
              post("watch.cancel", { handle });
            }
          });
        }
      });

      const statusBar = Object.freeze({
        set(text) {
          post("status.set", { text: text == null ? null : String(text) });
        }
      });

      const registrationFor = viewID => {
        let handlers = viewHandlers.get(viewID);
        if (!handlers) {
          handlers = { select: null, submit: null, open: null, close: null };
          viewHandlers.set(viewID, handlers);
        }
        return handlers;
      };
      const views = Object.freeze({
        register(viewID, options = {}) {
          requireString(viewID, "tenon.views.register");
          const source = options && typeof options === "object" ? options : {};
          registrationFor(viewID);
          post("view.register", {
            viewID,
            title: typeof source.title === "string" ? source.title : viewID,
            instanced: source.instanced === true
          });
        },
        set(viewID, specification, instanceID = null) {
          requireString(viewID, "tenon.views.set");
          post("view.set", {
            viewID,
            instanceID: typeof instanceID === "string" ? instanceID : null,
            specification: clone(specification || {})
          });
        },
        onSelect(viewID, handler) {
          requireFunction(handler, "tenon.views.onSelect");
          registrationFor(viewID).select = handler;
        },
        onSubmit(viewID, handler) {
          requireFunction(handler, "tenon.views.onSubmit");
          registrationFor(viewID).submit = handler;
        },
        onOpen(viewID, handler) {
          requireFunction(handler, "tenon.views.onOpen");
          registrationFor(viewID).open = handler;
        },
        onClose(viewID, handler) {
          requireFunction(handler, "tenon.views.onClose");
          registrationFor(viewID).close = handler;
        }
      });

      const palette = Object.freeze({
        registerProvider(providerID, options = {}) {
          requireString(providerID, "tenon.palette.registerProvider");
          const source = options && typeof options === "object" ? options : {};
          if (!paletteHandlers.has(providerID)) paletteHandlers.set(providerID, null);
          post("palette.register", {
            providerID,
            title: typeof source.title === "string" ? source.title : providerID
          });
        },
        onQuery(providerID, handler) {
          requireString(providerID, "tenon.palette.onQuery");
          requireFunction(handler, "tenon.palette.onQuery");
          paletteHandlers.set(providerID, handler);
        },
        setResults(providerID, revision, results) {
          requireString(providerID, "tenon.palette.setResults");
          if (typeof revision !== "number" || !Number.isInteger(revision) || revision < 0) {
            throw new TypeError("tenon.palette.setResults requires the integer revision from the query");
          }
          if (!Array.isArray(results)) {
            throw new TypeError("tenon.palette.setResults requires an array of results");
          }
          post("palette.results", { providerID, revision, results: clone(results) });
        }
      });

      // The supervised run-to-result loop, as JavaScript composition over the INTENT
      // adapter: open a pane → wait for the command to finish, scoped to that pane →
      // page its transcript back. It runs in the caller's generation under the caller's
      // principal, so every send below is policy-checked against that plugin's own
      // declared uses (`terminal.open.v1`, `terminal.wait.v1`,
      // `terminal.scrollback.read.v1` must all be in `intents.uses`). The function grants
      // nothing; it only spells the loop so every automation does not respell it.
      //
      // RECONSTRUCTED 2026-07-31 by session 247281cf from `AgentsRunTests`, after that
      // session destroyed the original (uncommitted) implementation with a careless
      // `git checkout` of this shared file. The tests are the surviving specification;
      // @f014e8e0's own version supersedes this one if they still hold it.
      const agents = Object.freeze({
        async run(request) {
          const source = request && typeof request === "object" ? request : {};
          if (typeof source.command !== "string" || source.command.length === 0) {
            throw new TypeError(
              "tenon.agents.run requires { command: string, arguments?: [string], workingDirectory?: string, timeoutMs?: number }"
            );
          }
          const argumentList = source.arguments === undefined ? [] : source.arguments;
          if (!Array.isArray(argumentList)
              || argumentList.some(value => typeof value !== "string")) {
            throw new TypeError("tenon.agents.run arguments must be an array of strings");
          }
          // POSIX single-quoting per token: a prompt can never become shell syntax.
          const commandLine = [source.command].concat(argumentList)
            .map(value => "'" + value.split("'").join("'\\''") + "'")
            .join(" ");
          const timeoutMs = typeof source.timeoutMs === "number"
              && Number.isFinite(source.timeoutMs)
              && source.timeoutMs > 0
            ? Math.floor(source.timeoutMs)
            : 600000;
          const deadline = Date.now() + timeoutMs;

          // Open the pane EMPTY, arm the wait, and only then send the command.
          //
          // Opening with the command loses every short run. `terminal.wait.v1` snapshots
          // its completion baseline when it is issued, so a command that finishes between
          // the open and the wait is already counted: the wait then sits out its entire
          // timeout waiting for a second finish that never comes. Measured against the
          // real provider, not reasoned about — a command that had already succeeded came
          // back `dev.tenon.agents.timeout`.
          //
          // Arming first closes the gap by construction: nothing has been sent, so nothing
          // can finish before the baseline is taken.
          const openInput = {};
          if (typeof source.workingDirectory === "string") {
            openInput.workingDirectory = source.workingDirectory;
          }
          const opened = await intents.send("terminal.open.v1", openInput);
          if (!opened.ok) return { ok: false, error: opened.error };
          const paneID = opened.value.paneID;
          const pane = { scope: { paneID } };

          let sent = false;
          for (;;) {
            const remaining = deadline - Date.now();
            if (remaining <= 0) {
              return { ok: false, error: { code: "dev.tenon.agents.timeout" }, paneID };
            }
            const waiting = intents.send("terminal.wait.v1", {
              condition: "command-finished",
              timeoutMs: Math.max(1, Math.min(55000, remaining))
            }, pane);
            if (!sent) {
              sent = true;
              // The pane may still be materialising; `terminal.write.v1` queues for it.
              const written = await intents.send(
                "terminal.write.v1",
                { text: commandLine + "\n" },
                pane
              );
              if (!written.ok) return { ok: false, error: written.error, paneID };
            }
            const waited = await waiting;
            if (!waited.ok) return { ok: false, error: waited.error, paneID };
            if (waited.value.met) break;
          }

          // Cursor-chained page walk. An `invalidated` page means the scrollback moved
          // under the cursor, so the pages already collected may not join up: throw them
          // away and start again, once. A second invalidation is a pane too unstable to
          // read, and saying so beats returning a transcript with a hole in it.
          let transcript = "";
          let cursor = null;
          let restarted = false;
          for (;;) {
            const readInput = {};
            if (cursor !== null) readInput.cursor = cursor;
            const page = await intents.send(
              "terminal.scrollback.read.v1",
              readInput,
              pane
            );
            if (!page.ok) return { ok: false, error: page.error, paneID };
            if (page.value.invalidated) {
              if (restarted) {
                return {
                  ok: false,
                  error: { code: "dev.tenon.agents.scrollback-unstable" },
                  paneID
                };
              }
              restarted = true;
              transcript = "";
              cursor = null;
              continue;
            }
            transcript += page.value.text || "";
            cursor = page.value.cursor;
            if (cursor === null || cursor === undefined) break;
          }
          return { ok: true, value: { paneID, transcript } };
        }
      });

      Object.defineProperty(globalThis, "__tenonStart", {
        configurable: false,
        writable: false,
        value(config) {
          if (phase !== "bootstrapping") throw new Error("runtime already bootstrapped");
          configuration = clone(config);
          phase = "staging";
          globalThis.tenon = Object.freeze({
            apiVersion: "1.0",
            intents,
            agents,
            settings,
            storage,
            path: pathAPI,
            events,
            timers,
            process: processAPI,
            fs,
            statusBar,
            views,
            palette,
            log(...values) {
              post("log", {
                message: values.map(value => {
                  if (typeof value === "string") return value;
                  try { return JSON.stringify(value); } catch (_) { return String(value); }
                }).join(" ")
              });
            }
          });
        }
      });

      Object.defineProperty(globalThis, "__tenonActivate", {
        configurable: false,
        writable: false,
        value() {
          if (phase !== "staging") throw new Error("runtime is not staging");
          phase = "active";
          return Array.from(providerHandlers.keys());
        }
      });

      Object.defineProperty(globalThis, "__tenonBeginShutdown", {
        configurable: false,
        writable: false,
        value() {
          if (phase === "stopped") return false;
          phase = "stopping";
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonSettleIntent", {
        configurable: false,
        writable: false,
        value(requestToken, result) {
          const resolve = pendingIntents.get(requestToken);
          if (!resolve) return false;
          pendingIntents.delete(requestToken);
          resolve(clone(result));
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonSettleList", {
        configurable: false,
        writable: false,
        value(requestToken, value) {
          const resolve = pendingLists.get(requestToken);
          if (!resolve) return false;
          pendingLists.delete(requestToken);
          resolve(clone(value));
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonInvokeProvider", {
        configurable: false,
        writable: false,
        value(callToken, name, input, metadata) {
          const handler = providerHandlers.get(name);
          if (!handler || phase !== "active") return false;
          const callState = {
            cancelled: false,
            nextNestedToken: 1,
            nestedTokens: new Set(),
            requestID: metadata.requestID
          };
          providerCalls.set(callToken, callState);
          const call = Object.freeze({
            get requestID() { return metadata.requestID; },
            get caller() { return clone(metadata.caller); },
            get scope() { return clone(metadata.scope); },
            get cancelled() { return callState.cancelled; },
            throwIfCancelled() {
              if (callState.cancelled) {
                const error = new Error("intent call cancelled");
                error.code = "tenon.cancelled";
                throw error;
              }
            },
            progress(progress) {
              if (callState.cancelled) return;
              post("provider.progress", { callToken, progress: clone(progress) });
            },
            send(nestedName, nestedInput = null, options = {}) {
              requireString(nestedName, "intent provider call.send");
              if (callState.cancelled) {
                return Promise.resolve(cancelledIntentResult(callState.requestID));
              }
              const nestedToken = `${callToken}-nested-${callState.nextNestedToken++}`;
              const completion = deferred();
              callState.nestedTokens.add(nestedToken);
              pendingNestedIntents.set(nestedToken, {
                callToken,
                resolve: completion.resolve
              });
              post("provider.send", {
                callToken,
                token: nestedToken,
                name: nestedName,
                input: clone(nestedInput),
                options: cleanIntentOptions(options)
              });
              return completion.promise;
            }
          });

          Promise.resolve()
            .then(() => handler(clone(input), call))
            .then(value => {
              settleNestedIntentsForCall(
                callToken,
                cancelledIntentResult(callState.requestID)
              );
              providerCalls.delete(callToken);
              post("provider.reply", {
                callToken,
                ok: true,
                value: clone(value)
              });
            })
            .catch(error => {
              settleNestedIntentsForCall(
                callToken,
                cancelledIntentResult(callState.requestID)
              );
              providerCalls.delete(callToken);
              const rawCode = error && typeof error.code === "string"
                ? error.code
                : "tenon.handler-failed";
              post("provider.reply", {
                callToken,
                ok: false,
                error: {
                  code: rawCode,
                  details: error && error.details !== undefined
                    ? clone(error.details)
                    : { message: error && error.message ? String(error.message) : String(error) },
                  retryable: error && error.retryable === true,
                  retryAfterMs: error
                    && Number.isSafeInteger(error.retryAfterMs)
                    && error.retryAfterMs >= 0
                    ? error.retryAfterMs
                    : null
                }
              });
            });
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonCancelProvider", {
        configurable: false,
        writable: false,
        value(callToken) {
          const state = providerCalls.get(callToken);
          if (!state) return false;
          state.cancelled = true;
          settleNestedIntentsForCall(
            callToken,
            cancelledIntentResult(state.requestID)
          );
          providerCalls.delete(callToken);
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonSettleNestedIntent", {
        configurable: false,
        writable: false,
        value(nestedToken, result) {
          const completion = pendingNestedIntents.get(nestedToken);
          if (!completion) return false;
          pendingNestedIntents.delete(nestedToken);
          const state = providerCalls.get(completion.callToken);
          if (state) state.nestedTokens.delete(nestedToken);
          completion.resolve(clone(result));
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonSettleStorage", {
        configurable: false,
        writable: false,
        value(requestToken, ok, message) {
          const completion = pendingStorageWrites.get(requestToken);
          if (!completion) return false;
          pendingStorageWrites.delete(requestToken);
          if (ok) {
            configuration.storage[completion.key] = clone(completion.value);
            completion.resolve(clone(completion.value));
          } else {
            const error = new Error(message || "storage write failed");
            error.code = "tenon.storage-write-failed";
            completion.reject(error);
          }
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonEmit", {
        configurable: false,
        writable: false,
        value(name, payload) {
          const owned = clone(payload);
          if (name === "settings.changed"
              && owned
              && typeof owned === "object"
              && typeof owned.key === "string"
              && Object.prototype.hasOwnProperty.call(owned, "value")) {
            configuration.settings[owned.key] = clone(owned.value);
          }
          const handlers = eventHandlers.get(name) || [];
          for (const handler of handlers) invokeAsync(`event ${name}`, handler, [clone(owned)]);
          return handlers.length;
        }
      });

      Object.defineProperty(globalThis, "__tenonFireTimer", {
        configurable: false,
        writable: false,
        value(handle) {
          const registration = timerHandlers.get(handle);
          if (!registration) return false;
          if (!registration.repeats) timerHandlers.delete(handle);
          invokeAsync(`timer ${handle}`, registration.handler, []);
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonProcessOutput", {
        configurable: false,
        writable: false,
        value(handle, stdout, stderr, overflowed) {
          const handlers = processHandlers.get(handle);
          if (!handlers) return false;
          if (stdout && handlers.stdout) invokeAsync(`process ${handle} stdout`, handlers.stdout, [stdout]);
          if (stderr && handlers.stderr) invokeAsync(`process ${handle} stderr`, handlers.stderr, [stderr]);
          if (overflowed && handlers.overflow) {
            invokeAsync(`process ${handle} overflow`, handlers.overflow, []);
          }
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonProcessExit", {
        configurable: false,
        writable: false,
        value(handle, status) {
          const handlers = processHandlers.get(handle);
          if (!handlers) return false;
          processHandlers.delete(handle);
          if (handlers.exit) invokeAsync(`process ${handle} exit`, handlers.exit, [status]);
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonWatchPaths", {
        configurable: false,
        writable: false,
        value(handle, paths) {
          const handler = watchHandlers.get(handle);
          if (!handler) return false;
          invokeAsync(`watch ${handle}`, handler, [clone(paths)]);
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonWatchRejected", {
        configurable: false,
        writable: false,
        value(handle) {
          return watchHandlers.delete(handle);
        }
      });

      Object.defineProperty(globalThis, "__tenonViewSelect", {
        configurable: false,
        writable: false,
        value(viewID, instanceID, itemID, value) {
          const handler = viewHandlers.get(viewID)?.select;
          if (!handler) return false;
          invokeAsync(`view ${viewID} select`, handler, [itemID, value, instanceID]);
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonViewSubmit", {
        configurable: false,
        writable: false,
        value(viewID, instanceID, itemID, text) {
          const handler = viewHandlers.get(viewID)?.submit;
          if (!handler) return false;
          invokeAsync(`view ${viewID} submit`, handler, [itemID, text, instanceID]);
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonViewOpen", {
        configurable: false,
        writable: false,
        value(viewID, instanceID) {
          const handler = viewHandlers.get(viewID)?.open;
          if (!handler) return false;
          invokeAsync(`view ${viewID} open`, handler, [instanceID]);
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonPaletteQuery", {
        configurable: false,
        writable: false,
        value(providerID, text, revision) {
          const handler = paletteHandlers.get(providerID);
          if (!handler) return false;
          invokeAsync(`palette ${providerID} query`, handler, [{ text, revision }]);
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonViewClose", {
        configurable: false,
        writable: false,
        value(viewID, instanceID) {
          const handler = viewHandlers.get(viewID)?.close;
          if (!handler) return false;
          invokeAsync(`view ${viewID} close`, handler, [instanceID]);
          return true;
        }
      });

      Object.defineProperty(globalThis, "__tenonShutdown", {
        configurable: false,
        writable: false,
        value() {
          phase = "stopped";
          for (const resolve of pendingIntents.values()) resolve({
            ok: false,
            error: {
              code: "tenon.provider-retired",
              retryable: false,
              outcome: "unknown"
            },
            meta: { requestID: "00000000-0000-0000-0000-000000000000" }
          });
          for (const completion of pendingNestedIntents.values()) completion.resolve({
            ok: false,
            error: {
              code: "tenon.provider-retired",
              retryable: false,
              outcome: "unknown"
            },
            meta: { requestID: "00000000-0000-0000-0000-000000000000" }
          });
          for (const completion of pendingStorageWrites.values()) {
            const error = new Error("plugin runtime stopped before storage commit");
            error.code = "tenon.provider-retired";
            completion.reject(error);
          }
          pendingIntents.clear();
          pendingLists.clear();
          pendingNestedIntents.clear();
          pendingStorageWrites.clear();
          providerCalls.clear();
          eventHandlers.clear();
          timerHandlers.clear();
          processHandlers.clear();
          watchHandlers.clear();
          viewHandlers.clear();
          paletteHandlers.clear();
          return true;
        }
      });
    })();
    """#
}
