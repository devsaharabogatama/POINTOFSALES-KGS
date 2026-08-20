import { forwardRef, type InputHTMLAttributes } from 'react'

type CurrencyInputProps = Omit<
  InputHTMLAttributes<HTMLInputElement>,
  'type' | 'value' | 'onChange' | 'inputMode'
> & {
  value: string | number
  onValueChange: (rawValue: string) => void
}

function normalizeCurrencyInput(value: string) {
  const digits = value.replace(/\D/g, '')
  return digits.replace(/^0+(?=\d)/, '')
}

function formatCurrencyInput(value: string | number) {
  const rawValue = String(value ?? '').trim()
  if (!rawValue) return ''

  // Postgres numeric values can arrive with decimal zeroes. Parse those as a
  // number first, otherwise "100000.0000" would look like extra Rupiah digits.
  const numericValue = Number(rawValue)
  if (/^\d+(?:\.\d+)?$/.test(rawValue) && Number.isFinite(numericValue)) {
    return new Intl.NumberFormat('id-ID', { maximumFractionDigits: 0 }).format(
      Math.round(numericValue),
    )
  }

  const normalized = normalizeCurrencyInput(rawValue)
  if (!normalized) return ''
  return new Intl.NumberFormat('id-ID', { maximumFractionDigits: 0 })
    .format(Number(normalized))
}

export const CurrencyInput = forwardRef<HTMLInputElement, CurrencyInputProps>(
  function CurrencyInput({ value, onValueChange, ...props }, ref) {
    return (
      <input
        {...props}
        ref={ref}
        type="text"
        inputMode="numeric"
        value={formatCurrencyInput(value)}
        onChange={(event) => onValueChange(normalizeCurrencyInput(event.target.value))}
      />
    )
  },
)
