# Dated salary models

F14 is an implemented subset for the audited **US calendar 2026 single-employee** and **UK 2026/27 England/Wales/Northern Ireland category-A** annualized standard cases, plus **Romanian 2026 monthly normal-condition employee cases**. Romanian dependants, school children, declared youth relief and employer CAM cost advance F15. **German 2026 current-wage employee payroll** follows the official BMF wage-tax program; see [Germany](#german-2026-employee-model). **Hungarian 2026 employee payroll and the átalányadó (flat-rate sole-trader) revenue-to-net model** follow the NAV 2026 information booklets; see [Hungary](#hungarian-2026-models). F16, other countries/years/profiles, full localized grammar and complete payroll settlement remain required unfinished work. The [rule manifest](payroll-rules.json) pins coverage, dates, sources, assumptions and version IDs. Separate independent fixtures cover [US/UK](../payroll-oracle-v1.json) and [Romanian monthly arithmetic](../romanian-payroll-oracle-v1.json).

```text
100000 gross in US for 2026
50000 gross in UK for 2026
100k USD gross
50k GBP brut
79180 net in gross in US for 2026
39519.6 GBP net in gross for 2026
5000 GBP/month gross in UK for 2026
100000 gross in US for 2026 in monthly
100000 USD gross in US for 2026 in hourly
f(x)=x gross in US for 2026
```

`gross`, `brut` and `brutto` select gross-to-net. Net-to-gross requires `net in gross` (the aliases also work as targets). `in net` may explicitly confirm the forward direction. A two-letter country and a `for` year/date are optional; `GB` normalizes to `UK`. Country precedence is explicit country, then input currency (USD→US, GBP→UK, EUR→DE, RON→RO, HUF→HU), then the injected payroll-region snapshot. Unsupported countries/years report unavailable; no other country's model or latest-year rules substitute for them. Known names take precedence over keyword markers. `date net N` remains invoice syntax.

For the US, a default year is the injected date's calendar year. For the UK it is the tax-year starting year: 6 April through 5 April. Explicit 2026 pins those rules without a clock requirement; a full date selects its containing US/UK tax year. Romania requires a full payroll date when pinned: `for 2026-07-01`. A year alone is refused because July changes the rules. Without a date Romania uses the injected current month. Historical pinned-rule arithmetic remains possible after the period ends; a missing/current unsupported period fails explicitly. No Core clock, web lookup or tax-provider request exists.

Bare US/UK amounts default to annual USD/GBP model units and retain a bare scalar result. Romanian bare amounts default to monthly RON model units. German bare amounts default to the annual EUR table. Monetary input converts to the model's native currency using the existing immutable rate context, returns that currency, and retains provenance. For US/UK, monthly/yearly `EarningsValue` inputs annualize, apply tax, then return the same period; monthly results divide the annual model by 12. For Romania, yearly inputs divide by 12 before monthly calculation, and yearly results project twelve identical selected-rule months. Hourly/workday input must first be explicitly annualized. Output targets `in hourly/daily/monthly/yearly` reuse the earnings contract: hour/workday conversions use the caller's current calendar year and selected workday calendar, separately from a pinned payroll period. Parentheses delimit salary phrases inside arithmetic, rounding or other calls.

## US model

For annual gross `g`, the standard deduction is 16100; taxable ordinary wages are `max(0,g-16100)`. Progressive rates and taxable upper bounds are:

| Taxable upper bound (USD) | Rate |
| --- | --- |
| 12400 | 10% |
| 50400 | 12% |
| 105700 | 22% |
| 201775 | 24% |
| 256225 | 32% |
| 640600 | 35% |
| Above | 37% |

Employee Social Security is `min(g,184500)*6.2%`; Medicare is `g*1.45%`; Additional Medicare is `max(0,g-200000)*0.9%`. Net equals gross less all four deductions. This assumes a single employee under 65, not blind or another taxpayer's dependent, ordinary covered wages and the standard deduction. It omits credits, state/local tax, special/itemized deductions, other income, pension/benefit elections and employer contributions. It is an annualized rate-schedule calculation, not a completed tax return or W-4/pay-period withholding engine. [IRS rate schedule/deduction](https://www.irs.gov/irb/2025-45_IRB), [IRS FICA](https://www.irs.gov/taxtopics/tc751), [SSA cap](https://www.ssa.gov/OACT/cola/cbb.html).

## UK model

The personal allowance is `max(0,12570-max(0,g-100000)/2)`. Taxable income is nonnegative gross minus that allowance. It is charged 20% through 37700, 40% from there through 125140, and 45% above. Employee category-A National Insurance is `8%*min(max(0,g-12570),37700)+2%*max(0,g-50270)`. Net subtracts income tax and NI. The model uses continuous allowance taper and annual thresholds; it excludes Scotland, student loans, pension/benefit elections, other income/reliefs and employer NI. Actual PAYE allowance/pay-period and settlement rounding are outside this model. Twelve monthly NI thresholds are not silently substituted for the published annual threshold. [HMRC employer tables](https://www.gov.uk/guidance/rates-and-thresholds-for-employers-2026-to-2027), [allowance taper](https://www.gov.uk/income-tax-rates), [taxable bands after allowance](https://www.gov.uk/government/publications/rates-and-allowances-income-tax/income-tax-rates-and-allowances-current-and-past).

Contains public sector information licensed under the [Open Government Licence v3.0](https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).

## Inverse, exactness and lifecycle

Each US/UK model has a finite known list of gross-income breakpoints (income bands, deduction/taper transitions and contribution thresholds). Their net is continuous and strictly increasing between and across these points. Net-to-gross searches bounded segments, solves that segment's affine equation exactly and recomputes the forward net for equality before publishing. It never iterates toward a guessed gross or uses display-rounded target amounts. Romania uses the separate discrete inverse below.

Amounts must be rational scalars/money without physical units or percentage type, nonnegative and bounded to 100 million annually; inverse targets must also fit a gross within that bound. Exact rational operations share existing 4096-bit, computation, cancellation, recursion and sheet budgets. A precision/computation failure is explicit. Upstream approximate amounts retain `≈` and their provenance; inverse equality concerns represented inputs, not their uncertainty. Financial scalars display four decimal places, money uses its currency precision, and authoritative values remain unrounded. No cent settlement is implied by monetary display.

`CalculationStep.Payroll` retains annual gross/net, available allowance/deduction, taxable income, every named deduction, model/year, direction, source URLs and approximation provenance. Explanations disclose profile, period, rule version, deductions and exclusions through the existing surface. Computed results are not persisted as authoritative data; saved source reconstructs them after restart.

Per-line date and payroll-region dependencies invalidate only consumers when their snapshots change. Explicit country/currency and pinned year need neither region inference nor date work. Hour/workday output additionally tracks the existing workday dependencies, including source holiday declarations and saved calls. Windows reuses its visible-only date lifecycle for date-dependent models; static models start no timer/provider. Complete global region settings, OS region-change validation, additional countries/years/profiles and statutory settlement remain open gates.

## Romanian monthly employee model

```text
5000 gross in RO for 2026-07-01
5000 lei gross
3000 net in gross in RO for 2026-07-01
5000 gross in RO for 2026-07-01 with 2 dependants
5000 gross in RO for 2026-07-01 with 1 school child
5000 gross in RO for 2026-07-01 with 2 dependants and 1 school child
5000 gross in RO for 2026-07-01 with youth relief
4500 gross in RO for 2026-07-01 with basic salary 4325
4325 gross in RO for 2026-07-01 without minimum relief
5000 gross in RO for 2026-07-01 without main job
5000 RON gross in RO for 2026-07-01 in employer cost
```

The model assumes a full month in normal working conditions, a main job, no benefits or leave, basic salary equal to gross, no dependants/children or youth relief, and eligibility for minimum-wage relief when its salary conditions hold. The latter includes full-time work and no disqualifying basic-pay reduction. These are disclosed model assumptions, not findings about the employee. `without minimum relief` disables that assumption; `with basic salary N` declares contractual basic pay separately from gross including bonuses. `without main job` disables personal deductions and minimum relief. It cannot be combined with claimed personal deductions. Special-sector, part-time, partial-month, leave, benefits, disability and voluntary-deduction profiles remain unavailable.

`with N dependants` states the **total eligible dependants**, including children. Without that option the count defaults to claimed school children, otherwise zero. The base table caps at four or more; input counts are bounded to 100. `with N school children` claims the additional 100 RON per eligible child for this parent only, including school enrollment and the required no-double-claim conditions. It does not add those children a second time to an explicit total. `with youth relief` asserts eligibility for the additional 15% deduction; age is not inferred. Eligibility and supporting documents remain the caller's responsibility. These literal profile modifiers are Calc's initial grammar, pending localization review.

The [official table, Article 77](https://static.anaf.ro/static/10/Anaf/legislatie/Cod_fiscal_norme_2023.htm) determines base personal deduction from gross, the minimum in force in the payroll month and dependants. Its transcribed 41 bands / 205 rates are retained separately from the implementation. Through minimum gross, rates are 20/25/30/35/45%; each next 50 whole lei reduces the rate by 0.5 percentage points. Above minimum plus 2000 the base deduction is zero. Youth relief is 15% of minimum through that same ceiling. School-child relief is 100 RON each regardless of gross. Total applied deductions cannot exceed monthly income available after contributions and the tax-free amount.

The minimum is **4050 RON January–June** ([HG 1506/2024](https://static.anaf.ro/static/10/Anaf/legislatie/HG_1506_2024.pdf)) and **4325 RON July–December** ([HG 146/2026](https://static.anaf.ro/static/10/Anaf/legislatie/HG_146_2026.pdf)). [OUG 89/2025 Article III](https://static.anaf.ro/static/10/Anaf/legislatie/OUG_89_2025.pdf) provides 300/200 RON relief respectively, conditional on basic salary equaling the dated minimum and gross not exceeding 4300/4600 RON, plus the eligibility conditions above. This model excludes the benefits that the legislation treats separately when measuring that ceiling.

For contribution base `gross - minimumRelief`, CAS is 25%, CASS 10%, and employer CAM 2.25%. Base and youth deductions, contribution fields and income tax use whole-leu half-up rounding. ANAF's [January](https://static.anaf.ro/static/10/Anaf/Declaratii_R/AplicatiiDec/structura_D112_0126_300326.pdf) and [July](https://static.anaf.ro/static/10/Anaf/Declaratii_R/AplicatiiDec/structura_D112_0726_070926.pdf) validation documents describe arithmetic contribution/parameter-field rounding and raising positive sub-leu contributions to one leu. [OUG 59/2005](https://legislatie.just.ro/Public/DetaliiDocument/69523) establishes whole-leu tax rounding. Taxable income is nonnegative contribution base minus rounded CAS/CASS and applied personal deduction; income tax is 10% of that base. Net subtracts CAS, CASS and income tax from gross. Employer cost adds CAM to gross; it is an allocation for one employee, not a multiemployee employer's aggregate declaration.

The supported monthly gross and inverse target are **whole lei**, with full-month gross at least the dated minimum and at most 8333333 RON (within the existing annual bound). Annual inputs must divide into whole-leu monthly amounts. Fractional-leu gross, partial-month minima and other settlement profiles fail explicitly; this subset does not establish complete statutory payroll coverage. Generic Calc currency conversion is planning arithmetic with preserved snapshot provenance, **not** the statutory BNR payroll conversion route. Explicit annual outputs use twelve identical months under the chosen month's rules and are not a mixed-rule 2026 settlement.

Rounded net is non-monotone across deduction/relief transitions: default July gross 4325 yields 2699, while 4326 yields 2614 because minimum relief and the first deduction band change. The inverse partitions at every such boundary. Within a fixed band, integer CAS and CASS rounding jumps occur on disjoint gross steps, so net is nondecreasing. It searches intervals in ascending gross order, uses a bounded integer lower-bound search only inside eligible intervals, and recomputes exact net. The result is the **lowest supported whole-leu gross producing the requested net exactly**; other gross values can produce the same net. No solution is an explicit error. The independent oracle exhaustively enumerates gross amounts through 20000 across 26 month/profile groups, checking 3822 forward cases and lowest inverse answers without sharing the interval algorithm.

`PayrollEvidence.Romanian` preserves payroll month, monthly gross/net/basic salary, contribution base, exempt amount, individual and applied deductions, taxable income, employer CAM/cost and declared profile. Existing annual fields are explicitly twelve-month projections of that one selected monthly model. Saved source rebuilds them after restart; results do not become authoritative persisted payroll data.

## German 2026 employee model

```text
60000 gross in DE for 2026
60000 brutto in DE
60000 EUR gross
6000 EUR/month gross in DE for 2026
37561 net in gross in DE for 2026
6000 EUR/month gross in DE for 2026 with tax class 3 with 2 children with child allowance 2 with church tax 9%
6000 EUR/month gross in DE for 2026 with health surcharge 2.5% with Saxony
6000 EUR/month gross in DE for 2026 without childless surcharge
```

The wage tax, solidarity surcharge and church-tax base are the **BMF machine wage-tax program for 2026** (PAP, BMF-Schreiben 12.11.2025, IV C 5 - S 2361/00025/016/028, BStBl 2025 I S. 1948, Anlage 1; pseudo-code `Lohnsteuer2026.xml` version 1.0, Stand 2025-10-23). [GermanWageTax2026](../../../../src/QNotch.Calculator.Engine/GermanWageTax2026.cs) ports its current-wage path with the program's own scales and rounding directions: MPARA, MRE4JL, MRE4ABZ, MBERECH, MZTABFB, MLSTJAHR, UPEVP (with the 2026 unemployment-insurance part and 1,900 EUR cap), MVSPKVPV, MVSPHB, UPMLST, UPTAB26, MST5_6, MSOLZ and UPANTEIL. Inputs are fixed to KRV = ALV = PKV = 0, no Versorgungsbezüge, age relief, tax-card Freibetrag/Hinzurechnung, factor method or sonstige Bezüge.

Monthly input (`EUR/month`) runs one monthly payroll period (LZZ 2) with monthly contribution ceilings. A bare or yearly amount runs the annual table (LZZ 1) with annual ceilings; this is the annual wage tax of that wage, not twelve settled monthly runs or a tax assessment. Hour/workday inputs must be annualized first. The tax year is the calendar year; `for 2026` or a 2026 date pins it, otherwise the injected current date selects it. Other years fail.

Options: `with tax class N` (1–6, default 1); `with child allowance N` (Kinderfreibetragszähler ZKF in steps of 0.5, classes 1–4 only; it changes the solidarity/church base, not wage tax); `with N children` (care insurance only: no childless surcharge, and 0.25-point discounts for the second to fifth child, assumed under 25); `without childless surcharge` (childless and under 23); `with health surcharge N%` (the full kassenindividueller Zusatzbeitrag, default the 2026 average 2.9%); `with Saxony` (Saxony care split); `with church tax` (9%) or `with church tax 8%`. Eligibility is the caller's declaration. Romanian-only options and employer cost are refused for DE; German options are refused elsewhere.

Employee contributions use the published 2026 values: pension 9.3% and unemployment 1.3% up to 101,400 EUR a year (8,450 EUR a month); health 7.3% plus half the Zusatzbeitrag and care 1.8% (Saxony 2.3%) plus 0.6% childless surcharge, less 0.25% per discounted child, up to 69,750 EUR a year (5,812.50 EUR a month). Each employee share is rounded half up to cents per branch; church tax is the church base times the rate, truncated to cents. These two rounding conventions are Calc's declared model, not a cited statutory rule. Net is gross less wage tax, solidarity surcharge, church tax and the four contributions. Gross must be whole cents above 2,000 EUR a month or 24,000 EUR a year, because Minijob and Übergangsbereich contributions are not modelled; the upper bound is the shared 100 million EUR a year.

Net-to-gross returns the **lowest whole-cent gross whose net equals the target exactly**. Integer tax rounding makes net non-monotone by a few cents, so a bisection crossing is followed by a downward scan that stops only once net is more than a dip bound below the target (2 EUR monthly, 20 EUR annually), then an upward scan bounded the same way. The independent oracle observed at most 0.27 EUR (monthly) and 1.08 EUR (annual) dips in its exhaustive windows. A target skipped by rounding reports no exact gross.

Explanations state the rule version `DE-employee-2026-v1`, period, profile, every component, the Vorsorgepauschale and annual taxable income, exclusions and sources. `PayrollEvidence.German` keeps the period amounts; the generic annual fields project twelve identical months for monthly input. Sources: [PAP pseudo-code](https://www.bmf-steuerrechner.de/javax.faces.resource/daten/xmls/Lohnsteuer2026.xml.xhtml), [PAP Anlage 1 with test table](https://www.ihk-muenchen.de/ihk/documents/Recht-Steuern/Steuerrecht/Einkommensteuer/2025-11-12-PAP-2026-anlage-1.pdf) (which also states the 2026 ceilings and rates), [SVBezGrV 2026 § 4](https://www.gesetze-im-internet.de/svbezgrv_2026/__4.html), [§ 241 SGB V](https://www.gesetze-im-internet.de/sgb_5/__241.html) and the [2026 average Zusatzbeitrag notice](https://www.bundesanzeiger.de/pub/publication/oUJYVk8GYRXybnb9Y4h/content/oUJYVk8GYRXybnb9Y4h/BAnz%20AT%2010.11.2025%20B7.pdf). Evidence is in P4 German payroll.

## Hungarian 2026 models

```text
600000 gross in HU for 2026
600000 HUF gross
214662 net in gross in HU for 2026
600000 gross in HU for 2026 with 2 children
600000 gross in HU for 2026 with 1 children with 3 dependants
600000 gross in HU for 2026 with youth relief
600000 gross in HU for 2026 with mothers exemption with 2 children
600000 gross in HU for 2026 with first marriage
600000 gross in HU for 2026 in employer cost
7000000 gross in HU for 2026 with átalányadó
600000 HUF/month gross in HU for 2026 with átalányadó
20000000 gross in HU for 2026 with átalányadó with cost ratio 80%
7000000 gross in HU for 2026 with átalányadó with guaranteed minimum
7000000 gross in HU for 2026 with átalányadó without main job
7000000 gross in HU for 2026 with átalányadó as pensioner
5000000 net in gross in HU for 2026 with átalányadó
```

Two models share the HU country code. The tax year is the calendar year; `for 2026` or a 2026 date pins it, otherwise the injected current date selects it, and other years fail. Monetary input converts to HUF with generic Calc conversion and preserved snapshot provenance; this is not a statutory MNB conversion. An amount written with a currency (converted, or HUF split into months) is rounded half up to whole forints in the model unit (month for employees, year for átalányadó), and the explanation says so; plain numbers must already be whole forints. A plain employee amount is monthly; above the 8,333,333 HUF monthly bound the error says so and suggests `x/year gross in HU` for a yearly salary. Amounts are whole forints, and every computed tax or contribution is rounded half up to whole forints. That rounding is Calc's declared convention, not a cited payroll rule.

**Employee (`HU-employee-2026-v1`).** Bare amounts are one full month of gross wages. Yearly amounts divide into twelve identical months, and yearly answers multiply by twelve. Gross is at most 8,333,333 HUF a month. TB járulék is 18.5% of gross, with no ceiling. SZJA is 15% of gross after allowances. Employer szocho is 13%, and `in employer cost` returns gross plus szocho. Allowances follow the order in NAV booklet 73. Every allowance is the caller's declaration of eligibility; Calc does not infer age, sex or family status.

- `with mothers exemption` declares one of the mothers' exemptions without a value cap: under-30 mothers, two-child mothers under 40 in 2026, or three-child and four-or-more-child mothers. It exempts the whole wage.
- `with youth relief` declares the under-25 exemption, capped at the July 2025 average gross wage of 715,765 HUF a month.
- `with first marriage` declares the first-marriage allowance, a 33,335 HUF monthly base reduction worth 5,000 HUF of tax.
- `with N children` claims the family allowance (családi kedvezmény) for N beneficiary dependants, in full by this person. `with M dependants` sets the total dependant count when it is larger. The monthly base reduction per beneficiary is 133,340 HUF with one dependant, 266,660 with two, and 440,000 with three or more. Allowance not used against the SZJA base becomes the family contribution relief: 15% of the unused amount, at most the TB járulék.

Net is gross minus TB járulék, plus the family contribution relief, minus SZJA. The minimum wage is 322,800 HUF and the guaranteed minimum wage 373,200 HUF ([426/2025. (XII. 23.) Korm. rendelet](https://njt.hu/jogszabaly/2025-426-20-22)). Their nets of 214,662 and 248,178 HUF are fixed checks. The model does not cover benefits, cafeteria, partial months, the disability (személyi) allowance, shared family allowance, KIVA or other employer reliefs, voluntary funds or minimum-base cases.

**Átalányadó (`HU-atalanyado-2026-v1`).** `with átalányadó` (also `atalanyado`, `átalányadózás` or `flat rate`) selects a sole trader under the flat-rate regime of Szja tv. 50–57. Its input is **revenue (bevétel)**, so "gross" here means revenue, not a salary. Bare amounts are annual revenue for one whole, insured tax year. `HUF/month` amounts are multiplied by twelve, and the answer divides back by twelve.

- **Income.** Income is revenue minus the cost ratio (költséghányad): 45% by default, or `with cost ratio 80%` or `90%` for the activities listed in Szja tv. 53. Revenue may not exceed ten times the annual minimum wage (38,736,000 HUF), or fifty times (193,680,000 HUF) at 90% for retail. Calc does not check which ÖVTJ'24 activity code applies.
- **SZJA.** Income up to half the annual minimum wage (1,936,800 HUF) is tax-free. SZJA is 15% of the taxable part after the same declared allowances, applied annually: the youth cap is 8,589,180 HUF and the first-marriage base 400,020 HUF.
- **Contributions.** Revenue is assumed to be earned evenly. TB járulék (18.5%) and szocho (13%) use NAV's quarterly cumulative (göngyölítéses) base. Each quarter, cumulative taxable income minus the bases already counted is divided over the quarter's three months.
  - **Main occupation (default):** each monthly base is at least the minimum wage, even when all income is tax-free. `with guaranteed minimum` uses the guaranteed minimum wage instead, for activities that require at least a secondary qualification. Since 2026 the szocho minimum is 100% of that wage, not 112.5%.
  - **`without main job`:** declares the activity runs beside 36-hour employment or full-time study, with no minimum base.
  - **`as pensioner`:** no TB járulék or szocho, and no family contribution relief. The extra szocho for pensioner mothers above four times the annual average wage cannot occur under the revenue limits.
- **Family contribution relief.** Unused family allowance gives 15% relief, capped at the járulék on the cumulative base. On minimum-base months the cap uses the part of the minimum that does not exceed that month's income.

Net is revenue minus SZJA, TB járulék and szocho, plus the relief. It is **before actual business costs**, local business tax (HIPA), VAT, chamber fees, suspension, sick pay and part-year activity. NAV's booklet 100 example, 7,000,000 HUF revenue at 45%, gives 3,850,000 income and 286,980 SZJA. With the 2026 minimum bases the model returns 5,492,836 HUF net.

Net-to-gross returns the **lowest whole-forint gross or revenue whose rounded net equals the target**. The unrounded net never decreases. Rounded net differs from it by at most 1.5 HUF for employees and 19 HUF for átalányadó. A bisection crossing is therefore followed by downward and upward scans that stop once net is 3 or 40 HUF past the target. A target that rounding skips reports no exact amount. The independent oracle simulates month by month with Python `Fraction`/`Decimal`. It reproduces the NAV anchors and records 597 forward cases across 23 profiles, each with a lowest inverse found by enumeration. Sources: [NAV booklet 100 (2026-02-20)](https://nav.gov.hu/pfile/file?path=/ugyfeliranytu/nezzen-utana/inf_fuz/2026/100.-Az-egyeni-vallalkozok-atalanyadozasanak-alapveto-szabalyai-2026.-02.-20), [NAV booklet 73 (2026-03-19)](https://nav.gov.hu/pfile/file?path=/ugyfeliranytu/nezzen-utana/inf_fuz/2026/73.-Szja-adoalap-kedvezmenyek-2026.-03.19), [Szja tv.](https://njt.hu/jogszabaly/1995-117-00-00), [Tbj.](https://njt.hu/jogszabaly/2019-122-00-00) and [Szocho tv.](https://njt.hu/jogszabaly/2018-52-00-00). `PayrollEvidence.Hungarian` keeps every component. For átalányadó it also keeps the twelve monthly liabilities: contribution base, TB járulék, szocho and the SZJA advance on cumulative income in each quarter's last month, adding up exactly to the annual amounts. Family contribution relief is settled annually. `PayrollBreakdownText` formats these without recomputing. Hover shows the SZJA/TB/szocho/net split and whether the answer is per month or per year; Explain (F1) and `calc-cli --explain` list the totals and months before the rule text. For employees, the generic annual fields project twelve identical months.
