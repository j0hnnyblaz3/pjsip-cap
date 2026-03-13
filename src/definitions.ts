export interface PjsipPlugin {
  echo(options: { value: string }): Promise<{ value: string }>;
}
