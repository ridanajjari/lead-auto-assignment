@IsTest
private class LeadAssignmentHandlerTest {

    private static final Id TECH_REP_ID    = UserInfo.getUserId(); // reuse running user as mock
    private static final Id FINANCE_REP_ID = UserInfo.getUserId();
    private static final Id DEFAULT_REP_ID = UserInfo.getUserId();

    // Inject mock rules so tests never depend on real CMT records in the org
    private static void loadMockRules() {
        LeadAssignmentHandler.rulesOverride = new List<Lead_Assignment_Rule__mdt>{
            // Most specific: Technology + France
            mockRule('Tech_France',    'Technology', 'France', TECH_REP_ID,    10),
            // Industry only: Finance, any country
            mockRule('Finance_Any',    'Finance',    null,     FINANCE_REP_ID, 20),
            // Catch-all: no industry, no country
            mockRule('Default',        null,         null,     DEFAULT_REP_ID, 999)
        };
    }

    private static Lead_Assignment_Rule__mdt mockRule(
        String devName, String industry, String country, Id userId, Integer priority
    ) {
        return new Lead_Assignment_Rule__mdt(
            DeveloperName        = devName,
            Industry__c          = industry,
            Country__c           = country,
            Assigned_User_Id__c  = userId,
            Priority__c          = priority,
            Is_Active__c         = true
        );
    }

    @IsTest
    static void testExactIndustryAndCountryMatch() {
        loadMockRules();
        Lead lead = new Lead(FirstName = 'Alice', LastName = 'Test',
                             Company = 'Acme', Industry = 'Technology', Country = 'France');
        insert lead;

        Lead result = [SELECT OwnerId FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(TECH_REP_ID, result.OwnerId, 'Tech + France lead should go to Tech rep');
    }

    @IsTest
    static void testIndustryOnlyMatch() {
        loadMockRules();
        Lead lead = new Lead(FirstName = 'Bob', LastName = 'Test',
                             Company = 'Acme', Industry = 'Finance', Country = 'Canada');
        insert lead;

        Lead result = [SELECT OwnerId FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(FINANCE_REP_ID, result.OwnerId, 'Finance lead (any country) should go to Finance rep');
    }

    @IsTest
    static void testCatchAllWhenNoRuleMatches() {
        loadMockRules();
        Lead lead = new Lead(FirstName = 'Carol', LastName = 'Test',
                             Company = 'Acme', Industry = 'Retail', Country = 'Brazil');
        insert lead;

        Lead result = [SELECT OwnerId FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(DEFAULT_REP_ID, result.OwnerId, 'Unmatched lead should fall through to the default catch-all');
    }

    @IsTest
    static void testUpdateOnlyReassignsWhenIndustryOrCountryChanges() {
        loadMockRules();
        Lead lead = new Lead(FirstName = 'Dave', LastName = 'Test',
                             Company = 'Acme', Industry = 'Technology', Country = 'France');
        insert lead;

        // Change only the LastName — should NOT trigger reassignment
        Id originalOwner = [SELECT OwnerId FROM Lead WHERE Id = :lead.Id].OwnerId;
        lead.LastName = 'Updated';
        update lead;

        Lead result = [SELECT OwnerId FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(originalOwner, result.OwnerId, 'Changing an irrelevant field should not change the owner');
    }

    @IsTest
    static void testUpdateReassignsWhenIndustryChanges() {
        loadMockRules();
        Lead lead = new Lead(FirstName = 'Eve', LastName = 'Test',
                             Company = 'Acme', Industry = 'Technology', Country = 'France');
        insert lead;

        lead.Industry = 'Finance';
        update lead;

        Lead result = [SELECT OwnerId FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(FINANCE_REP_ID, result.OwnerId, 'Changing industry should trigger a new assignment');
    }

    @IsTest
    static void testNoRulesLeavesOwnerUntouched() {
        LeadAssignmentHandler.rulesOverride = new List<Lead_Assignment_Rule__mdt>();
        Id currentUser = UserInfo.getUserId();

        Lead lead = new Lead(FirstName = 'Frank', LastName = 'Test',
                             Company = 'Acme', OwnerId = currentUser);
        insert lead;

        Lead result = [SELECT OwnerId FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(currentUser, result.OwnerId, 'With no rules, owner should remain unchanged');
    }

    @IsTest
    static void testBulkInsert200Leads() {
        loadMockRules();
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            leads.add(new Lead(FirstName = 'Bulk', LastName = 'Test ' + i,
                               Company = 'Acme', Industry = 'Technology', Country = 'France'));
        }

        Test.startTest();
        insert leads;
        Test.stopTest();

        List<Lead> results = [SELECT OwnerId FROM Lead WHERE Id IN :leads];
        for (Lead l : results) {
            Assert.areEqual(TECH_REP_ID, l.OwnerId, 'All bulk leads should be assigned to the Tech rep');
        }
    }

    @IsTest
    static void testCaseInsensitiveMatching() {
        loadMockRules();
        Lead lead = new Lead(FirstName = 'Grace', LastName = 'Test',
                             Company = 'Acme', Industry = 'TECHNOLOGY', Country = 'FRANCE');
        insert lead;

        Lead result = [SELECT OwnerId FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(TECH_REP_ID, result.OwnerId, 'Matching should be case-insensitive');
    }
}
