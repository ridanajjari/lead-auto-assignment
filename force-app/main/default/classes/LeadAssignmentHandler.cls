/**
 * Handler for LeadAssignmentTrigger.
 *
 * Assignment logic (evaluated in priority order, lowest number first):
 *   1. A rule with both Industry AND Country set   → most specific match
 *   2. A rule with only Industry set               → industry-wide match
 *   3. A rule with only Country set                → territory-wide match
 *   4. A rule with neither set (Priority = 999)    → default catch-all
 *
 * Rules are stored in Lead_Assignment_Rule__mdt so admins can manage
 * them without a code deployment.
 *
 * Test injection: set LeadAssignmentHandler.rulesOverride before calling
 * handle() to bypass the SOQL query in unit tests.
 */
public with sharing class LeadAssignmentHandler {

    @TestVisible
    private static List<Lead_Assignment_Rule__mdt> rulesOverride;

    public static void handle(List<Lead> newLeads, Map<Id, Lead> oldMap) {
        List<Lead_Assignment_Rule__mdt> rules = loadRules();
        if (rules.isEmpty()) return;

        for (Lead lead : newLeads) {
            if (shouldSkip(lead, oldMap)) continue;
            assignLead(lead, rules);
        }
    }

    // Only reassign on insert, or on update if Industry/Country changed
    private static Boolean shouldSkip(Lead lead, Map<Id, Lead> oldMap) {
        if (oldMap == null) return false;
        Lead old = oldMap.get(lead.Id);
        return lead.Industry == old.Industry && lead.Country == old.Country;
    }

    private static void assignLead(Lead lead, List<Lead_Assignment_Rule__mdt> rules) {
        for (Lead_Assignment_Rule__mdt rule : rules) {
            Boolean industryMatch = String.isBlank(rule.Industry__c)
                || rule.Industry__c.equalsIgnoreCase(lead.Industry);
            Boolean countryMatch  = String.isBlank(rule.Country__c)
                || rule.Country__c.equalsIgnoreCase(lead.Country);

            if (industryMatch && countryMatch) {
                lead.OwnerId = rule.Assigned_User_Id__c;
                return;
            }
        }
    }

    private static List<Lead_Assignment_Rule__mdt> loadRules() {
        if (rulesOverride != null) return rulesOverride;

        return [
            SELECT  DeveloperName, Label,
                    Industry__c, Country__c,
                    Assigned_User_Id__c, Priority__c, Is_Active__c
            FROM    Lead_Assignment_Rule__mdt
            WHERE   Is_Active__c = true
            ORDER BY Priority__c ASC
        ];
    }
}
