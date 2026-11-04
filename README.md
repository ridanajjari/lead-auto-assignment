# Lead Auto-Assignment Engine — Salesforce

Rule-based Lead assignment for Salesforce Sales Cloud. New Leads are automatically routed to the right sales rep based on Industry and Country — no code deployment needed to change the rules.

---

## Business Problem

When Leads come in from web forms, campaigns, or imports, they land in a queue or on a generic owner. Sales managers then manually reassign them — wasting time and slowing response time. This solution auto-routes every Lead to the correct rep the moment it's created.

---

## How It Works

```
Lead created or updated
        │
        ▼
LeadAssignmentTrigger (before insert / before update)
        │
        ▼
LeadAssignmentHandler loads rules from Custom Metadata
        │
        ├─ Rule: Industry = Technology, Country = France  (Priority 10)
        ├─ Rule: Industry = Finance, any country          (Priority 20)
        └─ Rule: catch-all, no filter                     (Priority 999)
        │
        ▼
First matching rule wins → Lead.OwnerId updated (no DML, runs before-trigger)
```

---

## Assignment Rules — Configured by Admins, No Code Needed

Rules live in `Lead_Assignment_Rule__mdt` (Custom Metadata). Admins manage them in Setup → Custom Metadata Types — no developer needed after the initial deployment.

| Priority | Industry   | Country | Assigned To     |
|----------|-----------|---------|-----------------|
| 10       | Technology | France  | Tech France Rep |
| 20       | Finance    | (any)   | Finance Team Rep|
| 999      | (any)      | (any)   | Default Rep     |

**Matching logic (most specific first):**
1. Industry + Country both match
2. Only Industry matches (Country left blank = wildcard)
3. Only Country matches (Industry left blank = wildcard)
4. Catch-all rule (both blank, high priority number)

---

## Project Structure

```
force-app/main/default/
├── triggers/
│   └── LeadAssignmentTrigger.trigger        # Thin trigger, delegates to handler
├── classes/
│   ├── LeadAssignmentHandler.cls            # Core assignment logic
│   └── LeadAssignmentHandlerTest.cls        # 8 test scenarios
├── objects/
│   └── Lead_Assignment_Rule__mdt/           # Custom Metadata Type definition
│       └── fields/                          # 5 custom fields
└── customMetadata/
    ├── Lead_Assignment_Rule.Tech_France.md-meta.xml
    ├── Lead_Assignment_Rule.Finance_Any.md-meta.xml
    └── Lead_Assignment_Rule.Default_Catchall.md-meta.xml
```

---

## Deployment

```bash
# 1. Clone and authenticate
git clone https://github.com/YOUR_USERNAME/lead-auto-assignment.git
cd lead-auto-assignment
sf org login web --alias my-org

# 2. Deploy everything
sf project deploy start --target-org my-org

# 3. Update the sample records with real User IDs
#    Go to Setup → Custom Metadata Types → Lead Assignment Rule → Manage Records
#    Replace REPLACE_WITH_USER_ID with actual Salesforce User IDs

# 4. Run tests
sf apex run test --target-org my-org --test-level RunLocalTests --wait 10
```

---

## Test Coverage

| Test Method | Scenario |
|-------------|----------|
| `testExactIndustryAndCountryMatch` | Technology + France → Tech rep |
| `testIndustryOnlyMatch` | Finance + any country → Finance rep |
| `testCatchAllWhenNoRuleMatches` | Unknown industry/country → default rep |
| `testUpdateOnlyReassignsWhenIndustryOrCountryChanges` | Irrelevant field update → no reassignment |
| `testUpdateReassignsWhenIndustryChanges` | Industry changes → new assignment |
| `testNoRulesLeavesOwnerUntouched` | Empty rule set → owner unchanged |
| `testBulkInsert200Leads` | 200 leads in one batch → all correctly assigned |
| `testCaseInsensitiveMatching` | "TECHNOLOGY" matches "Technology" |

---

## Key Salesforce Concepts Demonstrated

- `before insert / before update` trigger — no extra DML, ownership set in memory
- **Custom Metadata Types** — admin-configurable rules, deployable as metadata
- **Dependency injection via `@TestVisible`** — mocks CMT in tests without querying the org
- Bulk-safe handler pattern — one SOQL query for all leads in the transaction
- `equalsIgnoreCase()` for robust string matching

---

## Author

Built by [Your Name] — Salesforce Developer & Administrator  
[LinkedIn](#) · [Trailhead](#)
