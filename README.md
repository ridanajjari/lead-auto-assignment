# Lead Auto-Assignment Engine — Salesforce

Rule-based Lead assignment for Salesforce Sales Cloud. When a Lead is created (or its Industry or Country changes), a before-save trigger sets its owner to a user or queue chosen by admin-maintained Custom Metadata rules, so changing the routing does not need a code deployment.

---

## Business Problem

When Leads come in from web forms, campaigns, or imports, they land on a generic owner and sales managers reassign them by hand, which slows response time. This trigger routes each Lead to the configured rep or queue as it is saved.

---

## How It Works

```
Lead inserted, or updated with a new Industry / Country
        │
        ▼
LeadAssignmentTrigger (before insert / before update)
        │
        ▼
LeadAssignmentHandler
  1. loads active Lead_Assignment_Rule__mdt records
  2. resolves every assignee name in bulk
       usernames  -> active Users        (one User query)
       queue names -> queues for Lead     (one QueueSobject query)
     rules whose assignee can't be resolved are skipped (WARN debug, no error)
  3. sorts rules most specific first, then by Priority__c
        │
        ▼
First matching rule wins → Lead.OwnerId set in memory (before-save, no extra DML)
```

---

## Assignment Rules — Configured by Admins

Rules live in `Lead_Assignment_Rule__mdt` (Custom Metadata). Admins manage them in Setup → Custom Metadata Types → Lead Assignment Rule → Manage Records.

| Field              | Meaning                                                                                  |
| ------------------ | ---------------------------------------------------------------------------------------- |
| `Industry__c`      | Lead Industry to match (case-insensitive). Blank = any industry.                         |
| `Country__c`       | Lead Country to match (case-insensitive). Blank = any country.                           |
| `Assignee_Type__c` | `User` (default when blank) or `Queue`.                                                  |
| `Assignee__c`      | The user's **Username**, or the queue's **DeveloperName** (API name). Never a record Id. |
| `Priority__c`      | Tiebreaker between rules of the same specificity. Lower number wins.                     |
| `Is_Active__c`     | Only active rules are evaluated.                                                         |

**Matching order (most specific first):**

1. Industry **and** Country set
2. Only Industry **or** only Country set — these two kinds are equally specific; `Priority__c` decides between them
3. Catch-all (both blank)

Within the same level, the lower `Priority__c` wins, then `DeveloperName` alphabetically. The first rule that matches the Lead sets `OwnerId`. If no rule matches, the owner is left unchanged.

**Assignee resolution:**

- `User`: the username must belong to an **active** user.
- `Queue`: the DeveloperName must belong to a queue that has **Lead** in its supported objects.
- A rule whose assignee is blank, unknown, inactive, or a queue without Lead support is **skipped**: a `WARN` line is written to the debug log and evaluation continues with the next matching rule. A misconfigured rule never blocks a Lead save.
- Names are resolved in bulk and cached in static maps for the rest of the transaction: at most one User query and one QueueSobject query per trigger invocation, and none on later invocations in the same transaction unless new assignee names appear. Reading the rules themselves uses a Custom Metadata query, which does not count against the SOQL query limit.

### Shipped sample records

The three sample records (`Tech_France`, `Finance_Any`, `Default_Catchall`) ship **inactive** with `Assignee__c = REPLACE_WITH_USERNAME`, so deploying them into any org cannot change Lead ownership or break Lead saves. Set a real username (or queue) and tick **Is Active** to use them.

| Sample             | Industry   | Country | Priority |
| ------------------ | ---------- | ------- | -------- |
| `Tech_France`      | Technology | France  | 10       |
| `Finance_Any`      | Finance    | (any)   | 20       |
| `Default_Catchall` | (any)      | (any)   | 999      |

---

## Project Structure

```
force-app/main/default/
├── triggers/
│   └── LeadAssignmentTrigger.trigger        # Thin trigger, delegates to handler
├── classes/
│   ├── LeadAssignmentHandler.cls            # Rule loading, assignee resolution, matching
│   └── LeadAssignmentHandlerTest.cls        # 15 test methods
├── objects/
│   └── Lead_Assignment_Rule__mdt/           # Custom Metadata Type definition
│       └── fields/                          # 6 custom fields
├── customMetadata/                          # 3 inactive sample rules
└── permissionsets/
    └── Lead_Auto_Assignment.permissionset-meta.xml
```

---

## Deployment

The target org must support Apex and Custom Metadata Types (e.g. a Developer Edition org).

```bash
# 1. Clone and authenticate
git clone https://github.com/ridanajjari/lead-auto-assignment.git
cd lead-auto-assignment
sf org login web --alias my-org

# 2. Deploy everything
sf project deploy start --source-dir force-app --target-org my-org --wait 30

# 3. Assign the permission set (Apex class access for the handler)
sf org assign permset --name Lead_Auto_Assignment --target-org my-org

# 4. Run the tests
sf apex run test --target-org my-org --class-names LeadAssignmentHandlerTest --code-coverage --result-format human --wait 30
```

5. Configure the rules: Setup → Custom Metadata Types → Lead Assignment Rule → Manage Records. For each rule you want, set `Assignee__c` to a real username (or set `Assignee_Type__c = Queue` and use a Lead queue's DeveloperName), then tick **Is Active**.

The trigger runs for every Lead save whether or not the permission set is assigned. The Custom Metadata Type has no grant in the permission set: only Apex reads it.

---

## Tests

`LeadAssignmentHandlerTest` creates its own data in `@TestSetup`: three active reps, one inactive rep (all on a non-admin Salesforce-license profile that can edit Leads), a queue that supports Lead and a queue that only supports Case. Rules are injected through the `@TestVisible` `rulesOverride` field, so the tests do not depend on the org's Custom Metadata records.

| Test Method                                       | Scenario                                                                    |
| ------------------------------------------------- | --------------------------------------------------------------------------- |
| `testHandlerAssignsAwayFromInsertingUser`         | Technology + France → Tech rep, and the owner is not the inserting user     |
| `testIndustryOnlyMatch`                           | Finance + any country → Finance rep                                         |
| `testCatchAllWhenNoSpecificRuleMatches`           | Unmatched lead → catch-all rep                                              |
| `testMoreSpecificRuleWinsOverLowerPriorityNumber` | Industry + Country beats single-criterion beats catch-all, despite priority |
| `testPriorityBreaksTieWithinSameSpecificity`      | Industry-only vs Country-only → lower `Priority__c` wins                    |
| `testUnknownUsernameIsSkippedWithoutError`        | Unknown username → rule skipped, falls through to catch-all                 |
| `testInactiveUserIsSkippedWithoutError`           | Inactive user → rule skipped, falls through to catch-all                    |
| `testOnlyUnresolvableRulesLeaveOwnerUntouched`    | Placeholder / blank assignees → insert succeeds, owner unchanged            |
| `testQueueAssignee`                               | Queue rule → Lead owned by the queue                                        |
| `testQueueThatDoesNotSupportLeadIsSkipped`        | Queue without Lead support → rule skipped                                   |
| `testUpdateIgnoresIrrelevantFieldChanges`         | Update of an unrelated field → no reassignment                              |
| `testUpdateReassignsWhenIndustryChanges`          | Industry change → reassigned                                                |
| `testNoRulesLeavesOwnerUntouched`                 | No rules → owner unchanged                                                  |
| `testCaseInsensitiveMatching`                     | "TECHNOLOGY" / "FRANCE" match "Technology" / "France"                       |
| `testBulkInsert200LeadsResolvesAssigneesOnce`     | 200 mixed leads → correct owners, ≤ 2 queries, cache reused on next insert  |

---

## Verification

Not yet verified in an org. On 2026-11-12 the available org (API 68.0) was a Base Edition trial that does not allow Apex or Custom Metadata Type deployment, so the deploy was rejected and the tests have not been run. No coverage figure is claimed. Prettier (`npm run prettier:verify`, which parses the Apex) and ESLint (`npm run lint`) pass.

---

## Known Limits

- Assignee lookups run with the inserting user's sharing (`with sharing`). If that user cannot see the assignee User record, the rule is skipped.
- The tests create three active users with a full Salesforce license; an org with fewer than three free Salesforce licenses will fail the test setup.
- Matching is on exact (case-insensitive) Industry and Country values; there is no partial or list matching.
- Updates only re-run assignment when Industry or Country changes; a manual owner change is kept otherwise.

---

## Key Salesforce Concepts Demonstrated

- `before insert / before update` trigger — ownership set in memory, no extra DML
- **Custom Metadata Types** — admin-configurable rules, deployable as metadata
- Bulk assignee resolution with a per-transaction static cache
- Defensive configuration handling — bad rules are logged and skipped, never thrown
- **`@TestVisible` injection** — rules are injected in tests instead of relying on org records
- `Comparable` for deterministic rule ordering

---

## Author

**Rida Najjari** — Salesforce Consultant, Developer & Administrator

4x Salesforce Certified: Platform Administrator · Platform App Builder · Platform Developer I · Associate

- LinkedIn: [linkedin.com/in/rida-najjari](https://www.linkedin.com/in/rida-najjari)
- GitHub: [github.com/ridanajjari](https://github.com/ridanajjari)
