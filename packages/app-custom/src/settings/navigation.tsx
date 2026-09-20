import { Button } from "@opencode/ui-custom/button"
import { Icon } from "@opencode/ui-custom/icon"
import { Menu } from "@opencode/ui-custom/menu"
import { Tabs } from "@opencode/ui-custom/tabs"
import { For, Show, type ComponentProps, type JSX } from "solid-js"

export type SettingsNavItem = {
  value: string
  label: string
  icon: ComponentProps<typeof Icon>["name"]
  disabled?: boolean
  onPrefetch?: () => void
}

export type SettingsNavGroup = {
  label?: string
  items: readonly SettingsNavItem[]
}

export function SettingsNavigation(props: {
  value: string
  groups: readonly SettingsNavGroup[]
  backLabel: string
  onBack: () => void
  onChange: (value: string) => void
  children: JSX.Element
}) {
  const current = () => props.groups.flatMap((group) => group.items).find((item) => item.value === props.value)

  return (
    <Tabs orientation="vertical" variant="settings" value={props.value} onChange={props.onChange} class="settings">
      <div class="settings-mobile-nav">
        <button type="button" class="settings-back" onClick={props.onBack}>
          <Icon name="arrow-left" size="small" class="settings-back-icon" />
          <span>{props.backLabel}</span>
        </button>
        <Menu placement="bottom-end" gutter={8}>
          <Menu.Trigger as={Button} size="normal" variant="outline" class="settings-mobile-menu-trigger">
            <span>{current()?.label}</span>
            <Icon name="chevron-down" size="small" />
          </Menu.Trigger>
          <Menu.Portal>
            <Menu.Content class="settings-mobile-menu" onEscapeKeyDown={(event) => event.stopPropagation()}>
              <Menu.RadioGroup value={props.value} onChange={props.onChange}>
                <For each={props.groups}>
                  {(group, index) => (
                    <>
                      <Show when={index() > 0}>
                        <Menu.Separator />
                      </Show>
                      <For each={group.items}>
                        {(item) => (
                          <Menu.RadioItem
                            value={item.value}
                            disabled={item.disabled}
                            closeOnSelect
                            onPointerEnter={(event: PointerEvent) => {
                              if (item.disabled || event.pointerType === "touch") return
                              item.onPrefetch?.()
                            }}
                            onFocus={() => !item.disabled && item.onPrefetch?.()}
                          >
                            <Icon name={item.icon} />
                            {item.label}
                          </Menu.RadioItem>
                        )}
                      </For>
                    </>
                  )}
                </For>
              </Menu.RadioGroup>
            </Menu.Content>
          </Menu.Portal>
        </Menu>
      </div>
      <Tabs.List>
        <div class="settings-nav">
          <button type="button" class="settings-back" onClick={props.onBack}>
            <Icon name="arrow-left" size="small" class="settings-back-icon" />
            <span>{props.backLabel}</span>
          </button>
          <div class="flex flex-col gap-4 w-full">
            <For each={props.groups}>
              {(group) => (
                <div class="flex flex-col gap-1 w-full">
                  <Show when={group.label}>
                    <span class="px-2 text-11-regular text-v2-text-text-muted">{group.label}</span>
                  </Show>
                  <For each={group.items}>
                    {(item) => (
                      <Tabs.Trigger
                        value={item.value}
                        disabled={item.disabled}
                        onPointerEnter={(event: PointerEvent) => {
                          if (item.disabled || event.pointerType === "touch") return
                          item.onPrefetch?.()
                        }}
                        onFocus={() => !item.disabled && item.onPrefetch?.()}
                      >
                        <Icon name={item.icon} />
                        <span class="truncate">{item.label}</span>
                      </Tabs.Trigger>
                    )}
                  </For>
                </div>
              )}
            </For>
          </div>
        </div>
      </Tabs.List>
      {props.children}
    </Tabs>
  )
}
