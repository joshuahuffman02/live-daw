import { useEffect, type RefObject } from 'react'

const FOCUSABLE = [
  'button:not([disabled])',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  'a[href]',
  '[tabindex]:not([tabindex="-1"])',
].join(',')

export function useDialogFocusTrap(
  open: boolean,
  dialogRef: RefObject<HTMLElement | null>,
  onClose: () => void,
) {
  useEffect(() => {
    if (!open) return

    const dialog = dialogRef.current
    if (!dialog) return

    const returnFocus = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null

    const focusable = () => Array.from(
      dialog.querySelectorAll<HTMLElement>(FOCUSABLE),
    ).filter((element) => !element.hidden && element.getAttribute('aria-hidden') !== 'true')

    const initial = focusable()[0] ?? dialog
    initial.focus()

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose()
        return
      }

      if (event.key !== 'Tab') return
      const controls = focusable()
      if (controls.length === 0) {
        event.preventDefault()
        dialog.focus()
        return
      }

      const first = controls[0]
      const last = controls[controls.length - 1]
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }

    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
      returnFocus?.focus()
    }
  }, [open, dialogRef, onClose])
}
