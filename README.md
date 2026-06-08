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

<code>'unregistered' | 'registering' | 'registered' | 'unregistering' | 'failed'</code>


#### CallState

<code>'calling' | 'incoming' | 'early' | 'connecting' | 'confirmed' | 'disconnected' | 'held'</code>


#### AudioRoute

<code>'speaker' | 'earpiece' | 'bluetooth'</code>


#### PushPlatform

<code>'apns' | 'fcm' | 'web'</code>


#### PushEnvironment

APNs environment for the push token. Sandbox is Xcode debug builds;
production is TestFlight / App Store. The PBX uses this to pick the
correct APNs endpoint per-token so a debug install and a TestFlight
install of the same app can coexist against the same global config.

<code>'sandbox' | 'production'</code>

</docgen-api>
