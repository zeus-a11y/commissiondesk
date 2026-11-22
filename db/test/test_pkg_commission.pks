CREATE OR REPLACE PACKAGE test_pkg_commission AS
  --%suite(pkg_commission: monthly agent commission run)
  --%rollback(auto)

  --%beforeeach
  PROCEDURE setup_hierarchy;

  --%context(rates)

  --%test(first-year premium earns the first-year rate)
  PROCEDURE base_first_year_rate;
  --%test(renewal premium earns the renewal rate and no overrides)
  PROCEDURE renewal_rate_no_override;
  --%test(the rate in force on the due date applies, across a dated rate change)
  PROCEDURE dated_rate_change;
  --%test(the financial year starts on 1 April)
  PROCEDURE fy_start_is_april;

  --%endcontext

  --%context(hierarchy)

  --%test(first-year business pays 10% override to the senior and 5% to the manager)
  PROCEDURE overrides_two_levels;
  --%test(an agent cannot be made their own ancestor)
  --%throws(-20011)
  PROCEDURE hierarchy_cycle_rejected;
  --%test(agent changes are audited with the PAN masked)
  PROCEDURE audit_masks_pan;

  --%endcontext

  --%context(exceptions queue)

  --%test(a receipt with no configured rate is queued and the rest of the batch is still paid)
  PROCEDURE missing_rate_queued_batch_continues;
  --%test(renewals paid after an agent leaves are orphan exceptions; before, they are paid)
  PROCEDURE orphan_after_termination;

  --%endcontext

  --%context(clawback and bonus)

  --%test(a lapse in policy year 1 claws back all first-year commission from every recipient)
  PROCEDURE clawback_full_year_one;
  --%test(a lapse in policy year 2 claws back half)
  PROCEDURE clawback_half_year_two;
  --%test(recalculating a month never claws back the same policy twice)
  PROCEDURE clawback_once;
  --%test(first-year volume above the tier earns a bonus on first-year commission)
  PROCEDURE bonus_tier;

  --%endcontext

  --%context(statements and tax)

  --%test(no TDS below Rs 20,000 in the FY; on crossing it, TDS catches up on the whole FY)
  PROCEDURE tds_threshold_catch_up;
  --%test(an agent without a PAN has TDS at 20%)
  PROCEDURE tds_no_pan;
  --%test(a debit balance is carried forward and recovered from the next month)
  PROCEDURE debit_carried_forward;

  --%endcontext

  --%context(run lifecycle)

  --%test(an approved month is locked)
  --%throws(-20001)
  PROCEDURE approved_period_locked;
  --%test(a month cannot be run while an earlier month is unapproved)
  --%throws(-20003)
  PROCEDURE previous_month_must_be_approved;
  --%test(a future month cannot be run)
  --%throws(-20002)
  PROCEDURE future_period_rejected;
  --%test(recalculating a month gives identical results)
  PROCEDURE recalculation_is_idempotent;
  --%test(overlapping commission-rate windows are rejected)
  --%throws(-20010)
  PROCEDURE overlapping_rate_rejected;

  --%endcontext
END test_pkg_commission;
/
