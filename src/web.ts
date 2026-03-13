import { WebPlugin } from '@capacitor/core';

import type { PjsipPlugin } from './definitions';

export class PjsipWeb extends WebPlugin implements PjsipPlugin {
  async echo(options: { value: string }): Promise<{ value: string }> {
    console.log('ECHO', options);
    return options;
  }
}
