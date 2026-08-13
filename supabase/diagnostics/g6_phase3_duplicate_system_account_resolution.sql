-- G6 corrective phase 3 focused diagnostic: duplicate system-account choice.
-- SAFETY: SELECT-only. Shows Finance master identity and aggregate reference
-- counts only; no transaction amount, source document, or party data.

WITH target_functions(function_key,original_seed_code) AS (
    VALUES
        ('COGS','5110'),
        ('INVENTORY_ASSET','1310'),
        ('SALES_REVENUE','4110'),
        ('STOCK_GAIN_INCOME','7110'),
        ('STOCK_LOSS_EXPENSE','6130')
), candidates AS (
    SELECT
        company.company_code,
        target.function_key,
        target.original_seed_code,
        account.id AS account_id,
        account.account_code,
        account.account_name,
        account.account_type,
        account.normal_balance,
        account.is_system_account,
        account.is_postable,
        account.is_active,
        account.created_at,
        upper(btrim(account.account_code)) = target.original_seed_code
            AS matches_original_seed_code
    FROM target_functions target
    JOIN public.chart_of_accounts account
      ON account.system_function_key = target.function_key
     AND account.is_active
     AND account.is_postable
    JOIN public.companies company ON company.id = account.company_id
    WHERE company.status = 'ACTIVE'
), reference_counts AS (
    SELECT
        candidate.*,
        (
            SELECT count(*)
            FROM public.transaction_account_rules rule
            WHERE rule.account_id = candidate.account_id
        ) AS transaction_rule_references,
        (
            SELECT count(*)
            FROM public.company_account_function_fallbacks fallback
            WHERE fallback.account_id = candidate.account_id
        ) AS company_fallback_references,
        (
            SELECT count(*)
            FROM public.finance_journal_lines line
            WHERE line.account_id = candidate.account_id
        ) AS canonical_journal_references,
        (
            SELECT count(*)
            FROM public.journal_entries entry
            WHERE entry.account_id = candidate.account_id
        ) AS legacy_journal_references,
        (
            SELECT count(*)
            FROM public.financial_events event
            WHERE event.company_id = (
                SELECT account.company_id
                FROM public.chart_of_accounts account
                WHERE account.id = candidate.account_id
            )
              AND position(
                  candidate.account_id::TEXT IN COALESCE(event.amounts,'{}')::TEXT
              ) > 0
        ) AS event_snapshot_references
    FROM candidates candidate
)
SELECT
    company_code,
    function_key,
    account_code,
    account_name,
    account_type,
    normal_balance,
    is_system_account,
    matches_original_seed_code,
    transaction_rule_references,
    company_fallback_references,
    canonical_journal_references,
    legacy_journal_references,
    event_snapshot_references,
    created_at,
    CASE
        WHEN transaction_rule_references
             + company_fallback_references
             + canonical_journal_references
             + legacy_journal_references
             + event_snapshot_references > 0
            THEN 'HAS_HISTORY_REFERENCE'
        WHEN matches_original_seed_code THEN 'ORIGINAL_MINIMUM_COA'
        ELSE 'UNREFERENCED_DUPLICATE_CANDIDATE'
    END AS resolution_evidence
FROM reference_counts
ORDER BY company_code,function_key,
    matches_original_seed_code DESC,created_at,account_code;
