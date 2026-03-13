import { registerPlugin } from '@capacitor/core';

import type { PjsipPlugin } from './definitions';

const Pjsip = registerPlugin<PjsipPlugin>('Pjsip', {
  web: () => import('./web').then((m) => new m.PjsipWeb()),
});

export * from './definitions';
export { Pjsip };
