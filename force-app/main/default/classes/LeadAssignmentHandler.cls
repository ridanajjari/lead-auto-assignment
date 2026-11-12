/**
 * Handler for LeadAssignmentTrigger.
 *
 * Rules are stored in Lead_Assignment_Rule__mdt so admins can manage
 * them without a code deployment. A rule matches when its Industry__c and
 * Country__c match the Lead (blank = wildcard, case-insensitive). Active
 * rules are evaluated most specific first, and the first match sets OwnerId:
 *   1. Industry AND Country set          (specificity 2)
 *   2. Only Industry OR only Country set (specificity 1)
 *   3. Neither set (catch-all)           (specificity 0)
 * Within the same specificity, lower Priority__c wins; DeveloperName breaks
 * any remaining tie so the order is deterministic.
 *
 * Assignees are configured by name, never by record Id:
 *   - Assignee_Type__c = 'User' (or blank): Assignee__c is a Username.
 *     Only active users are used.
 *   - Assignee_Type__c = 'Queue': Assignee__c is a queue DeveloperName.
 *     Only queues that support the Lead object (QueueSobject) are used.
 * A rule whose assignee cannot be resolved is skipped with a WARN debug
 * message; it never throws, so a misconfigured rule cannot block Lead saves.
 *
 * Assignee names are resolved in bulk and cached in static maps for the
 * transaction: at most one User query and one QueueSobject query per trigger
 * invocation, and none on later invocations in the same transaction unless
 * new assignee names appear.
 *
 * Test injection: set LeadAssignmentHandler.rulesOverride before the DML
 * to bypass the custom metadata query in unit tests.
 */
public with sharing class LeadAssignmentHandler {
  @TestVisible
  private static final String TYPE_USER = 'User';
  @TestVisible
  private static final String TYPE_QUEUE = 'Queue';

  @TestVisible
  private static List<Lead_Assignment_Rule__mdt> rulesOverride;

  // Lower-cased name -> Id. A null value means "looked up, not usable",
  // so unresolvable names are not queried again in the same transaction.
  private static final Map<String, Id> USER_IDS_BY_USERNAME = new Map<String, Id>();
  private static final Map<String, Id> QUEUE_IDS_BY_NAME = new Map<String, Id>();

  public static void handle(List<Lead> newLeads, Map<Id, Lead> oldMap) {
    List<Lead> leadsToAssign = new List<Lead>();
    for (Lead lead : newLeads) {
      if (!shouldSkip(lead, oldMap)) {
        leadsToAssign.add(lead);
      }
    }
    if (leadsToAssign.isEmpty()) {
      return;
    }

    List<ResolvedRule> rules = resolveRules(loadRules());
    if (rules.isEmpty()) {
      return;
    }

    for (Lead lead : leadsToAssign) {
      assignLead(lead, rules);
    }
  }

  // Only reassign on insert, or on update if Industry/Country changed
  private static Boolean shouldSkip(Lead lead, Map<Id, Lead> oldMap) {
    if (oldMap == null) {
      return false;
    }
    Lead old = oldMap.get(lead.Id);
    return lead.Industry == old.Industry && lead.Country == old.Country;
  }

  private static void assignLead(Lead lead, List<ResolvedRule> rules) {
    for (ResolvedRule resolved : rules) {
      if (resolved.matches(lead)) {
        lead.OwnerId = resolved.ownerId;
        return;
      }
    }
  }

  /**
   * Turns rules into (rule, owner Id) pairs sorted most specific first,
   * resolving every assignee name in bulk. Rules whose assignee cannot be
   * resolved are dropped with a WARN debug line, so evaluation falls
   * through to the next matching rule.
   */
  private static List<ResolvedRule> resolveRules(
    List<Lead_Assignment_Rule__mdt> rules
  ) {
    Set<String> usernamesToQuery = new Set<String>();
    Set<String> queueNamesToQuery = new Set<String>();
    for (Lead_Assignment_Rule__mdt rule : rules) {
      String key = normalise(rule.Assignee__c);
      if (key == null) {
        continue;
      }
      if (isQueue(rule)) {
        if (!QUEUE_IDS_BY_NAME.containsKey(key)) {
          queueNamesToQuery.add(key);
        }
      } else if (!USER_IDS_BY_USERNAME.containsKey(key)) {
        usernamesToQuery.add(key);
      }
    }
    if (!usernamesToQuery.isEmpty()) {
      cacheActiveUsers(usernamesToQuery);
    }
    if (!queueNamesToQuery.isEmpty()) {
      cacheLeadQueues(queueNamesToQuery);
    }

    List<ResolvedRule> resolved = new List<ResolvedRule>();
    for (Lead_Assignment_Rule__mdt rule : rules) {
      String key = normalise(rule.Assignee__c);
      Id ownerId;
      if (key != null) {
        ownerId = isQueue(rule)
          ? QUEUE_IDS_BY_NAME.get(key)
          : USER_IDS_BY_USERNAME.get(key);
      }
      if (ownerId == null) {
        System.debug(
          LoggingLevel.WARN,
          'LeadAssignmentHandler: skipping rule ' +
            rule.DeveloperName +
            ' - assignee "' +
            rule.Assignee__c +
            '" (' +
            (isQueue(rule) ? TYPE_QUEUE : TYPE_USER) +
            ') is blank, unknown, inactive, or not a Lead queue.'
        );
        continue;
      }
      resolved.add(new ResolvedRule(rule, ownerId));
    }
    resolved.sort();
    return resolved;
  }

  private static void cacheActiveUsers(Set<String> usernames) {
    for (String username : usernames) {
      USER_IDS_BY_USERNAME.put(username, null);
    }
    for (User u : [
      SELECT Id, Username
      FROM User
      WHERE Username IN :usernames AND IsActive = TRUE
    ]) {
      USER_IDS_BY_USERNAME.put(u.Username.toLowerCase(), u.Id);
    }
  }

  private static void cacheLeadQueues(Set<String> queueNames) {
    for (String queueName : queueNames) {
      QUEUE_IDS_BY_NAME.put(queueName, null);
    }
    for (QueueSobject qs : [
      SELECT QueueId, Queue.DeveloperName
      FROM QueueSobject
      WHERE SobjectType = 'Lead' AND Queue.DeveloperName IN :queueNames
    ]) {
      QUEUE_IDS_BY_NAME.put(qs.Queue.DeveloperName.toLowerCase(), qs.QueueId);
    }
  }

  private static Boolean isQueue(Lead_Assignment_Rule__mdt rule) {
    return TYPE_QUEUE.equalsIgnoreCase(rule.Assignee_Type__c);
  }

  private static String normalise(String value) {
    return String.isBlank(value) ? null : value.trim().toLowerCase();
  }

  private static List<Lead_Assignment_Rule__mdt> loadRules() {
    if (rulesOverride != null) {
      return rulesOverride;
    }

    return [
      SELECT
        DeveloperName,
        Label,
        Industry__c,
        Country__c,
        Assignee_Type__c,
        Assignee__c,
        Priority__c,
        Is_Active__c
      FROM Lead_Assignment_Rule__mdt
      WHERE Is_Active__c = TRUE
      ORDER BY Priority__c ASC
    ];
  }

  private class ResolvedRule implements Comparable {
    public final Lead_Assignment_Rule__mdt rule;
    public final Id ownerId;
    public final Integer specificity;

    public ResolvedRule(Lead_Assignment_Rule__mdt rule, Id ownerId) {
      this.rule = rule;
      this.ownerId = ownerId;
      this.specificity =
        (String.isBlank(rule.Industry__c) ? 0 : 1) +
        (String.isBlank(rule.Country__c) ? 0 : 1);
    }

    // Most specific first, then lowest Priority__c (blank last), then DeveloperName.
    public Integer compareTo(Object other) {
      ResolvedRule that = (ResolvedRule) other;
      if (specificity != that.specificity) {
        return specificity > that.specificity ? -1 : 1;
      }
      Decimal thisPriority = rule.Priority__c;
      Decimal thatPriority = that.rule.Priority__c;
      if (thisPriority != thatPriority) {
        if (thisPriority == null) {
          return 1;
        }
        if (thatPriority == null) {
          return -1;
        }
        return thisPriority < thatPriority ? -1 : 1;
      }
      String thisName = rule.DeveloperName == null ? '' : rule.DeveloperName;
      String thatName = that.rule.DeveloperName == null
        ? ''
        : that.rule.DeveloperName;
      return thisName.compareTo(thatName);
    }

    public Boolean matches(Lead lead) {
      Boolean industryMatch =
        String.isBlank(rule.Industry__c) ||
        rule.Industry__c.equalsIgnoreCase(lead.Industry);
      Boolean countryMatch =
        String.isBlank(rule.Country__c) ||
        rule.Country__c.equalsIgnoreCase(lead.Country);
      return industryMatch && countryMatch;
    }
  }
}
