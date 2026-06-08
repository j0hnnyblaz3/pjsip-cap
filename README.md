# capacitor-pjsip

Capacitor PJSIP plugin for SIP operations

## Install

To use npm

```bash
npm install capacitor-pjsip
````

To use yarn

```bash
yarn add capacitor-pjsip
```

Sync native files

```bash
npx cap sync
```

## API

<docgen-index>

* [`register(...)`](#register)
* [`unregister()`](#unregister)
* [`getRegistrationState()`](#getregistrationstate)
* [`makeCall(...)`](#makecall)
* [`answerCall(...)`](#answercall)
* [`hangupCall(...)`](#hangupcall)
* [`getActiveCalls()`](#getactivecalls)
* [`holdCall(...)`](#holdcall)
* [`muteCall(...)`](#mutecall)
* [`sendDtmf(...)`](#senddtmf)
* [`transferCall(...)`](#transfercall)
* [`setAudioRoute(...)`](#setaudioroute)
* [`registerPush()`](#registerpush)
* [`unregisterPush()`](#unregisterpush)
* [`checkPermissions()`](#checkpermissions)
* [`requestPermissions(...)`](#requestpermissions)
* [`addListener('callStateChanged', ...)`](#addlistenercallstatechanged-)
* [`addListener('registrationStateChanged', ...)`](#addlistenerregistrationstatechanged-)
* [`addListener('incomingCall', ...)`](#addlistenerincomingcall-)
* [`addListener('pushTokenUpdated', ...)`](#addlistenerpushtokenupdated-)
* [Interfaces](#interfaces)
* [Type Aliases](#type-aliases)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

### register(...)

```typescript
register(options: SipAccountConfig) => Promise<void>
```

| Param         | Type                                                          |
| ------------- | ------------------------------------------------------------- |
| **`options`** | <code><a href="#sipaccountconfig">SipAccountConfig</a></code> |

--------------------


### unregister()

```typescript
unregister() => Promise<void>
```

--------------------


### getRegistrationState()

```typescript
getRegistrationState() => Promise<{ state: RegistrationState; }>
```

**Returns:** <code>Promise&lt;{ state: <a href="#registrationstate">RegistrationState</a>; }&gt;</code>

--------------------


### makeCall(...)

```typescript
makeCall(options: { uri: string; displayName?: string; }) => Promise<{ callId: string; }>
```

Place an outbound call.

`displayName` is optional and, on iOS, is fed into CallKit's
`CXCallUpdate.localizedCallerName` so the Dynamic Island /
Phone-app UI shows the contact's display name instead of the
raw SIP URI / Firebase UID. Web ignores it (UI surfaces the
dialer-known name itself).

| Param         | Type                                                |
| ------------- | --------------------------------------------------- |
| **`options`** | <code>{ uri: string; displayName?: string; }</code> |

**Returns:** <code>Promise&lt;{ callId: string; }&gt;</code>

--------------------


### answerCall(...)

```typescript
answerCall(options: { callId: string; }) => Promise<void>
```

| Param         | Type                             |
| ------------- | -------------------------------- |
| **`options`** | <code>{ callId: string; }</code> |

--------------------


### hangupCall(...)

```typescript
hangupCall(options: { callId: string; }) => Promise<void>
```

| Param         | Type                             |
| ------------- | -------------------------------- |
| **`options`** | <code>{ callId: string; }</code> |

--------------------


### getActiveCalls()

```typescript
getActiveCalls() => Promise<{ calls: ActiveCall[]; }>
```

Enumerate calls the engine is currently tracking. Used for call
recovery: a freshly-(re)loaded client queries this on init and
re-adopts any in-flight call so it stays controllable.

**Returns:** <code>Promise&lt;{ calls: ActiveCall[]; }&gt;</code>

--------------------


### holdCall(...)

```typescript
holdCall(options: { callId: string; hold: boolean; }) => Promise<void>
```

| Param         | Type                                            |
| ------------- | ----------------------------------------------- |
| **`options`** | <code>{ callId: string; hold: boolean; }</code> |

--------------------


### muteCall(...)

```typescript
muteCall(options: { callId: string; mute: boolean; }) => Promise<void>
```

| Param         | Type                                            |
| ------------- | ----------------------------------------------- |
| **`options`** | <code>{ callId: string; mute: boolean; }</code> |

--------------------


### sendDtmf(...)

```typescript
sendDtmf(options: { callId: string; digit: string; }) => Promise<void>
```

| Param         | Type                                            |
| ------------- | ----------------------------------------------- |
| **`options`** | <code>{ callId: string; digit: string; }</code> |

--------------------


### transferCall(...)

```typescript
transferCall(options: { callId: string; target: string; }) => Promise<void>
```

| Param         | Type                                             |
| ------------- | ------------------------------------------------ |
| **`options`** | <code>{ callId: string; target: string; }</code> |

--------------------


### setAudioRoute(...)

```typescript
setAudioRoute(options: { route: AudioRoute; }) => Promise<void>
```

| Param         | Type                                                          |
| ------------- | ------------------------------------------------------------- |
| **`options`** | <code>{ route: <a href="#audioroute">AudioRoute</a>; }</code> |

--------------------


### registerPush()

```typescript
registerPush() => Promise<void>
```

--------------------


### unregisterPush()

```typescript
unregisterPush() => Promise<void>
```

--------------------


### checkPermissions()

```typescript
checkPermissions() => Promise<CallPermissionStatus>
```

Check current OS-level permission state for mic + camera without
prompting. Lets the UI decide whether to call `requestPermissions`
(state=='prompt'), proceed straight to the call (state=='granted'),
or show a deep-link-to-Settings nudge (state=='denied').

Web returns 'prompt' for both — the browser doesn't expose this
API for getUserMedia targets and prompts at media-acquire time.

**Returns:** <code>Promise&lt;<a href="#callpermissionstatus">CallPermissionStatus</a>&gt;</code>

--------------------


### requestPermissions(...)

```typescript
requestPermissions(options?: RequestPermissionsOptions | undefined) => Promise<CallPermissionStatus>
```

Pre-request mic (and optionally camera) permission ahead of the
first call. Without this, the iOS prompt only fires when the OS
actually opens the input device — which is the moment CallKit
tries to activate the audio session. A user who taps Deny at
that moment leaves the call broken with no clean recovery path.

The right time to call: just after a successful registration,
when the user has signaled intent (signed in to a phone-enabled
account) but isn't yet in the middle of a call.

Web: no-op that resolves with 'prompt' for both — browsers ask
at media-acquire time, not via a separate request API.

| Param         | Type                                                                            |
| ------------- | ------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#requestpermissionsoptions">RequestPermissionsOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#callpermissionstatus">CallPermissionStatus</a>&gt;</code>

--------------------


### addListener('callStateChanged', ...)

```typescript
addListener(event: 'callStateChanged', listener: (data: CallStateEvent) => void) => Promise<PluginListenerHandle>
```

| Param          | Type                                                                         |
| -------------- | ---------------------------------------------------------------------------- |
| **`event`**    | <code>'callStateChanged'</code>                                              |
| **`listener`** | <code>(data: <a href="#callstateevent">CallStateEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

--------------------


### addListener('registrationStateChanged', ...)

```typescript
addListener(event: 'registrationStateChanged', listener: (data: RegistrationStateEvent) => void) => Promise<PluginListenerHandle>
```

| Param          | Type                                                                                         |
| -------------- | -------------------------------------------------------------------------------------------- |
| **`event`**    | <code>'registrationStateChanged'</code>                                                      |
| **`listener`** | <code>(data: <a href="#registrationstateevent">RegistrationStateEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

--------------------


### addListener('incomingCall', ...)

```typescript
addListener(event: 'incomingCall', listener: (data: IncomingCallEvent) => void) => Promise<PluginListenerHandle>
```

| Param          | Type                                                                               |
| -------------- | ---------------------------------------------------------------------------------- |
| **`event`**    | <code>'incomingCall'</code>                                                        |
| **`listener`** | <code>(data: <a href="#incomingcallevent">IncomingCallEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

--------------------


### addListener('pushTokenUpdated', ...)

```typescript
addListener(event: 'pushTokenUpdated', listener: (data: PushTokenEvent) => void) => Promise<PluginListenerHandle>
```

| Param          | Type                                                                         |
| -------------- | ---------------------------------------------------------------------------- |
| **`event`**    | <code>'pushTokenUpdated'</code>                                              |
| **`listener`** | <code>(data: <a href="#pushtokenevent">PushTokenEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

--------------------


### Interfaces


#### SipAccountConfig

| Prop             | Type                                                  | Description                                                                                                                                                                                                                                                                                                                                        |
| ---------------- | ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`server`**     | <code>string</code>                                   |                                                                                                                                                                                                                                                                                                                                                    |
| **`port`**       | <code>number</code>                                   |                                                                                                                                                                                                                                                                                                                                                    |
| **`username`**   | <code>string</code>                                   |                                                                                                                                                                                                                                                                                                                                                    |
| **`password`**   | <code>string</code>                                   |                                                                                                                                                                                                                                                                                                                                                    |
| **`domain`**     | <code>string</code>                                   |                                                                                                                                                                                                                                                                                                                                                    |
| **`transport`**  | <code><a href="#siptransport">SipTransport</a></code> |                                                                                                                                                                                                                                                                                                                                                    |
| **`proxy`**      | <code>string</code>                                   |                                                                                                                                                                                                                                                                                                                                                    |
| **`pushToken`**  | <code>string</code>                                   | Opaque push token forwarded to the SBC in the REGISTER's `pn-tok` / contact params so the server can wake the app via VoIP push when an INVITE arrives. Currently informational — the iOS backend acquires its own token via PushKit and the SBC pairs by extension, but the field is forwarded for SBCs that key on the registered token instead. |
| **`srtpPolicy`** | <code><a href="#srtppolicy">SrtpPolicy</a></code>     | SRTP enforcement policy. Defaults to `mandatory` on iOS (clean RTP/SAVP profile, matches FreeSWITCH/dSIPRouter expectations). Ignored on web.                                                                                                                                                                                                      |


#### ActiveCall

A call the engine currently knows about. Returned by `getActiveCalls`
so a client that lost its in-memory state (web hot-reload, native
background→resume after the OS reclaimed the webview) can re-adopt
in-flight calls instead of orphaning them.

| Prop             | Type                                            |
| ---------------- | ----------------------------------------------- |
| **`callId`**     | <code>string</code>                             |
| **`state`**      | <code><a href="#callstate">CallState</a></code> |
| **`remoteUri`**  | <code>string</code>                             |
| **`callerName`** | <code>string</code>                             |


#### CallPermissionStatus

| Prop             | Type                                                        |
| ---------------- | ----------------------------------------------------------- |
| **`microphone`** | <code><a href="#permissionstate">PermissionState</a></code> |
| **`camera`**     | <code><a href="#permissionstate">PermissionState</a></code> |


#### RequestPermissionsOptions

| Prop             | Type                 | Description                                                                                                                  |
| ---------------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| **`microphone`** | <code>boolean</code> | Ask for microphone. Defaults to true — every audio call needs it.                                                            |
| **`camera`**     | <code>boolean</code> | Ask for camera. Defaults to false — only set true when the caller knows video might be used (e.g. before joining a meeting). |


#### PluginListenerHandle

| Prop         | Type                                      |
| ------------ | ----------------------------------------- |
| **`remove`** | <code>() =&gt; Promise&lt;void&gt;</code> |


#### CallStateEvent

| Prop            | Type                                            |
| --------------- | ----------------------------------------------- |
| **`callId`**    | <code>string</code>                             |
| **`state`**     | <code><a href="#callstate">CallState</a></code> |
| **`remoteUri`** | <code>string</code>                             |


#### RegistrationStateEvent

| Prop         | Type                                                            |
| ------------ | --------------------------------------------------------------- |
| **`state`**  | <code><a href="#registrationstate">RegistrationState</a></code> |
| **`reason`** | <code>string</code>                                             |


#### IncomingCallEvent

| Prop             | Type                | Description                                                                                                                                                                                                                                                                     |
| ---------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`callId`**     | <code>string</code> |                                                                                                                                                                                                                                                                                 |
| **`remoteUri`**  | <code>string</code> |                                                                                                                                                                                                                                                                                 |
| **`callerName`** | <code>string</code> |                                                                                                                                                                                                                                                                                 |
| **`callUuid`**   | <code>string</code> | The PBX-side call identifier, lifted from the INVITE's `X-Redyrect-Call-UUID` header when present. Lets the client address this specific call via REST (decline/hangup) and correlate with the FCM push that announced it. Optional — older PBX versions don't emit the header. |


#### PushTokenEvent

| Prop              | Type                                                        | Description                                                                                                                                                                                                                                                   |
| ----------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`token`**       | <code>string</code>                                         |                                                                                                                                                                                                                                                               |
| **`platform`**    | <code><a href="#pushplatform">PushPlatform</a></code>       |                                                                                                                                                                                                                                                               |
| **`environment`** | <code><a href="#pushenvironment">PushEnvironment</a></code> | APNs environment (`sandbox` or `production`). Emitted on iOS only — web/FCM don't have the same dual-endpoint setup. Lets the PBX route pushes to the right APNs server for THIS specific token so debug and TestFlight installs of the same app can coexist. |


### Type Aliases


#### SipTransport

<code>'udp' | 'tcp' | 'tls' | 'wss'</code>


#### SrtpPolicy

SRTP enforcement policy for outbound INVITEs:
- `disabled`: plain RTP, no SAVP offer
- `optional`: offer RTP/AVP with embedded crypto attribute (hybrid)
- `mandatory`: offer RTP/SAVP profile cleanly (recommended for SBCs
  like FreeSWITCH behind dSIPRouter which reject the OPTIONAL hybrid)

Currently consumed by the iOS native backend only; web (sip.js) leaves
SRTP policy to the SDP-handler factory and ignores this field. Declared
here so the JS layer can forward the admin VoIP-config override without
a type cast.

<code>'disabled' | 'optional' | 'mandatory'</code>


#### RegistrationState

Registration state values both backends produce.

Note: there's no `unregistering` — earlier drafts had one, but
neither the iOS PJSIP backend nor the web (sip.js) backend
surface that transient state. `unregister` simply flips from
`registered` to `unregistered` once the SBC ACKs.

<code>'unregistered' | 'registering' | 'registered' | 'failed'</code>


#### CallState

Call lifecycle states.

Cross-platform notes:
  • `calling` — outbound INVITE sent, no provisional response yet.
  • `early` — outbound 183 Session Progress received (e.g. ringback
    from the SBC). iOS distinguishes this; web's sip.js folds it
    into `connecting`, so web never emits `early`. UI treats
    `calling` and `early` identically ("Calling…").
  • `connecting` — 200 OK received, ACK in flight (web) or
    PJSIP_INV_STATE_CONNECTING transient (iOS).
  • `confirmed` — ACK done, media flowing.
  • `held` — synthesized: iOS derives from PJSIP media_status
    (LOCAL_HOLD or REMOTE_HOLD); web currently only emits this on
    local hold — see [[project_future_work]] for remote-hold
    synthesis on web.

<code>'calling' | 'incoming' | 'early' | 'connecting' | 'confirmed' | 'disconnected' | 'held'</code>


#### AudioRoute

<code>'speaker' | 'earpiece' | 'bluetooth'</code>


#### PermissionState

<code>'prompt' | 'prompt-with-rationale' | 'granted' | 'denied'</code>


#### PushPlatform

<code>'apns' | 'fcm' | 'web'</code>


#### PushEnvironment

APNs environment for the push token. Sandbox is Xcode debug builds;
production is TestFlight / App Store. The PBX uses this to pick the
correct APNs endpoint per-token so a debug install and a TestFlight
install of the same app can coexist against the same global config.

<code>'sandbox' | 'production'</code>

</docgen-api>
