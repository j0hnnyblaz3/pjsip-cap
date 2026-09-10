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

| Prop             | Type                                                  | Description                                                                                                                          |
| ---------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| **`server`**     | <code>string</code>                                   |                                                                                                                                      |
| **`port`**       | <code>number</code>                                   |                                                                                                                                      |
| **`username`**   | <code>string</code>                                   |                                                                                                                                      |
| **`password`**   | <code>string</code>                                   |                                                                                                                                      |
| **`domain`**     | <code>string</code>                                   |                                                                                                                                      |
| **`transport`**  | <code><a href="#siptransport">SipTransport</a></code> |                                                                                                                                      |
| **`proxy`**      | <code>string</code>                                   |                                                                                                                                      |
| **`pushToken`**  | <code>string</code>                                   |                                                                                                                                      |
| **`srtpPolicy`** | <code><a href="#srtppolicy">SrtpPolicy</a></code>     | Media encryption policy. Omit to leave the decision to the server. 'mandatory' fails the call rather than falling back to plain RTP. |


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


#### SipPermissionStatus

| Prop             | Type                                                              |
| ---------------- | ----------------------------------------------------------------- |
| **`microphone`** | <code><a href="#sippermissionstate">SipPermissionState</a></code> |


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

| Prop           | Type                                                  |
| -------------- | ----------------------------------------------------- |
| **`token`**    | <code>string</code>                                   |
| **`platform`** | <code><a href="#pushplatform">PushPlatform</a></code> |


### Type Aliases


#### SipTransport

<code>'udp' | 'tcp' | 'tls' | 'wss'</code>


#### SrtpPolicy

Media encryption policy handed to pjsip's `use_srtp`.

<code>'disabled' | 'optional' | 'mandatory'</code>


#### RegistrationState

<code>'unregistered' | 'registering' | 'registered' | 'unregistering' | 'failed'</code>


#### CallState

<code>'calling' | 'incoming' | 'early' | 'connecting' | 'confirmed' | 'disconnected' | 'held'</code>


#### AudioRoute

<code>'speaker' | 'earpiece' | 'bluetooth'</code>


#### SipPermissionState

Per-permission state, mirroring Capacitor's PermissionState vocabulary.

<code>'prompt' | 'prompt-with-rationale' | 'granted' | 'denied'</code>


#### PushPlatform

<code>'apns' | 'fcm' | 'web'</code>

</docgen-api>
