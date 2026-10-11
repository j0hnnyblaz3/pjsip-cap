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
* [`updateCallDisplay(...)`](#updatecalldisplay)
* [`checkPermissions()`](#checkpermissions)
* [`requestPermissions(...)`](#requestpermissions)
* [`registerPush()`](#registerpush)
* [`unregisterPush()`](#unregisterpush)
* [`addListener('callUpdated', ...)`](#addlistenercallupdated-)
* [`addListener('registrationStateChanged', ...)`](#addlistenerregistrationstatechanged-)
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
getActiveCalls() => Promise<{ calls: CallSnapshot[]; }>
```

Enumerate calls the engine is currently tracking. Used for call
recovery: a freshly-(re)loaded client queries this on init and
re-adopts any in-flight call so it stays controllable.

**Returns:** <code>Promise&lt;{ calls: CallSnapshot[]; }&gt;</code>

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


### updateCallDisplay(...)

```typescript
updateCallDisplay(options: { callId: string; displayName: string | null; }) => Promise<void>
```

Update the caller name shown by the OS call UI (CallKit on iOS,
ConnectionService on Android) for a call already in progress.
Pass null to clear a previous override.

| Param         | Type                                                          |
| ------------- | ------------------------------------------------------------- |
| **`options`** | <code>{ callId: string; displayName: string \| null; }</code> |

--------------------


### checkPermissions()

```typescript
checkPermissions() => Promise<SipPermissionStatus>
```

Current microphone permission, without prompting.

**Returns:** <code>Promise&lt;<a href="#sippermissionstatus">SipPermissionStatus</a>&gt;</code>

--------------------


### requestPermissions(...)

```typescript
requestPermissions(options?: { microphone?: boolean | undefined; } | undefined) => Promise<SipPermissionStatus>
```

Prompt for microphone permission.

| Param         | Type                                   |
| ------------- | -------------------------------------- |
| **`options`** | <code>{ microphone?: boolean; }</code> |

**Returns:** <code>Promise&lt;<a href="#sippermissionstatus">SipPermissionStatus</a>&gt;</code>

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


### addListener('callUpdated', ...)

```typescript
addListener(event: 'callUpdated', listener: (data: CallSnapshot) => void) => Promise<PluginListenerHandle>
```

Every change to every call, as a whole <a href="#callsnapshot">`CallSnapshot`</a>.

| Param          | Type                                                                     |
| -------------- | ------------------------------------------------------------------------ |
| **`event`**    | <code>'callUpdated'</code>                                               |
| **`listener`** | <code>(data: <a href="#callsnapshot">CallSnapshot</a>) =&gt; void</code> |

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

| Prop                     | Type                                                  | Description                                                                                                                                                                                                                                                                                                                                        |
| ------------------------ | ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`server`**             | <code>string</code>                                   |                                                                                                                                                                                                                                                                                                                                                    |
| **`port`**               | <code>number</code>                                   |                                                                                                                                                                                                                                                                                                                                                    |
| **`username`**           | <code>string</code>                                   |                                                                                                                                                                                                                                                                                                                                                    |
| **`password`**           | <code>string</code>                                   |                                                                                                                                                                                                                                                                                                                                                    |
| **`domain`**             | <code>string</code>                                   |                                                                                                                                                                                                                                                                                                                                                    |
| **`transport`**          | <code><a href="#siptransport">SipTransport</a></code> |                                                                                                                                                                                                                                                                                                                                                    |
| **`proxy`**              | <code>string</code>                                   |                                                                                                                                                                                                                                                                                                                                                    |
| **`pushToken`**          | <code>string</code>                                   | Opaque push token forwarded to the SBC in the REGISTER's `pn-tok` / contact params so the server can wake the app via VoIP push when an INVITE arrives. Currently informational — the iOS backend acquires its own token via PushKit and the SBC pairs by extension, but the field is forwarded for SBCs that key on the registered token instead. |
| **`srtpPolicy`**         | <code><a href="#srtppolicy">SrtpPolicy</a></code>     | Media encryption policy. Omit to leave the decision to the server. 'mandatory' fails the call rather than falling back to plain RTP.                                                                                                                                                                                                               |
| **`registerExpiresSec`** | <code>number</code>                                   | How the engine runs, from the PBX (`/me/sip-config`) — no platform keeps numbers or codec lists of its own. Seconds between REGISTER refreshes.                                                                                                                                                                                                    |
| **`keepAliveSec`**       | <code>number</code>                                   | Seconds between keep-alive pings on the registration connection.                                                                                                                                                                                                                                                                                   |
| **`codecs`**             | <code>string[]</code>                                 | Codecs to offer, in preference order, by encoding name (`OPUS`, `G722`, `PCMU` …, any case). Everything else is off; DTMF stays on. Native only — a browser negotiates its own WebRTC codecs.                                                                                                                                                      |


#### CallSnapshot

A call, whole. The one event every platform sends (`callUpdated`), every
time anything about the call changes, and what `getActiveCalls` returns.

Every platform keeps these rules, so a consumer never has to repair them:
  • One `callId` for the call's whole life — the PBX call id
    (`X-Redyrect-Call-UUID`) when the INVITE carries one.
  • Fields are only ever added: a later snapshot never drops the caller
    name or URI an earlier one carried.
  • `disconnected` is sent exactly once, with `end`, and nothing is sent
    for that call afterwards.

| Prop             | Type                                                    | Description                                                                                                                                                                                              |
| ---------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`callId`**     | <code>string</code>                                     |                                                                                                                                                                                                          |
| **`direction`**  | <code><a href="#calldirection">CallDirection</a></code> |                                                                                                                                                                                                          |
| **`state`**      | <code><a href="#callstate">CallState</a></code>         |                                                                                                                                                                                                          |
| **`remoteUri`**  | <code>string</code>                                     | The other party as SIP gave it, display name included when present (`"Ann Lee" &lt;sip:uid@host&gt;`). Empty only for a pushed call whose INVITE hasn't arrived and whose push had no number.            |
| **`callerName`** | <code>string</code>                                     | The other party's name as SIP gave it: the INVITE's From display name for incoming, the dialer's `displayName` for outgoing, the push's caller name for a pushed call. Unset when none of those had one. |
| **`callUuid`**   | <code>string</code>                                     | The PBX call id, when known. Equal to `callId` when present.                                                                                                                                             |
| **`answered`**   | <code>boolean</code>                                    | True once the call has been connected (`confirmed`) at any point.                                                                                                                                        |
| **`end`**        | <code><a href="#callend">CallEnd</a></code>             | Set on the `disconnected` snapshot only.                                                                                                                                                                 |


#### CallEnd

How a call ended — facts only. What that means to a person ("declined",
"busy", "no answer") is the app's to decide, from these and `answered`.

| Prop            | Type                             | Description                                                                                                                                         |
| --------------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`by`**        | <code>'local' \| 'remote'</code> | `local`: this device ended it (the app, the system call UI, a notification's Decline). `remote`: anything else — the far end, the PBX, the network. |
| **`sipStatus`** | <code>number</code>              | The SIP status the call ended with (486 busy, 603 decline, 487 cancelled, 408 timeout, 200 after a BYE …), when the engine has one.                 |
| **`sipReason`** | <code>string</code>              | The reason phrase that came with `sipStatus`.                                                                                                       |


#### SipPermissionStatus

| Prop             | Type                                                              |
| ---------------- | ----------------------------------------------------------------- |
| **`microphone`** | <code><a href="#sippermissionstate">SipPermissionState</a></code> |


#### PluginListenerHandle

| Prop         | Type                                      |
| ------------ | ----------------------------------------- |
| **`remove`** | <code>() =&gt; Promise&lt;void&gt;</code> |


#### RegistrationStateEvent

| Prop         | Type                                                            |
| ------------ | --------------------------------------------------------------- |
| **`state`**  | <code><a href="#registrationstate">RegistrationState</a></code> |
| **`reason`** | <code>string</code>                                             |


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

Consumed by the native backends (iOS, Android); web (sip.js) leaves
SRTP to the browser's DTLS-SRTP and ignores it. Omitted means the
backend's own default — the policy is the app's setting.

<code>'disabled' | 'optional' | 'mandatory'</code>


#### RegistrationState

Registration lifecycle states this plugin actually emits.

No `unregistering`: neither backend ever reports it. unregister() goes
straight from `registered` to `unregistered` once the far end ACKs the
de-REGISTER. Declaring it forced every consumer to handle a state that
cannot occur, and narrowing it away was reported as a type error against
accurate code.

<code>'unregistered' | 'registering' | 'registered' | 'failed'</code>


#### CallDirection

Which side placed the call.

<code>'incoming' | 'outgoing'</code>


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


#### SipPermissionState

Per-permission state, mirroring Capacitor's PermissionState vocabulary.

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
