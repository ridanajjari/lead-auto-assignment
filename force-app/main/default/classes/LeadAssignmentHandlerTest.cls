@IsTest
private class LeadAssignmentHandlerTest {
    private static final String TECH_REP = 'LAA Tech Rep';
    private static final String FINANCE_REP = 'LAA Finance Rep';
    private static final String DEFAULT_REP = 'LAA Default Rep';
    private static final String INACTIVE_REP = 'LAA Inactive Rep';
    private static final String LEAD_QUEUE = 'LAA_Test_Lead_Queue';
    private static final String CASE_ONLY_QUEUE = 'LAA_Test_Case_Only_Queue';

    @TestSetup
    static void createAssignees() {
        Id profileId = leadEditingProfileId();
        insert new List<User>{
            newUser(TECH_REP, profileId, true),
            newUser(FINANCE_REP, profileId, true),
            newUser(DEFAULT_REP, profileId, true),
            newUser(INACTIVE_REP, profileId, false)
        };

        Group leadQueue = new Group(Name = LEAD_QUEUE, DeveloperName = LEAD_QUEUE, Type = 'Queue');
        Group caseOnlyQueue = new Group(Name = CASE_ONLY_QUEUE, DeveloperName = CASE_ONLY_QUEUE, Type = 'Queue');
        insert new List<Group>{ leadQueue, caseOnlyQueue };
        insert new List<QueueSobject>{
            new QueueSobject(QueueId = leadQueue.Id, SobjectType = 'Lead'),
            new QueueSobject(QueueId = caseOnlyQueue.Id, SobjectType = 'Case')
        };
    }

    // ---------------------------------------------------------------- helpers

    // A non-admin profile with a full Salesforce license that can edit Leads.
    // Looked up by permissions rather than by name because standard profile
    // names are translated (e.g. "Utilisateur standard" in a French org).
    private static Id leadEditingProfileId() {
        List<ObjectPermissions> perms = [
            SELECT Parent.ProfileId
            FROM ObjectPermissions
            WHERE
                SobjectType = 'Lead'
                AND PermissionsEdit = TRUE
                AND PermissionsModifyAllRecords = FALSE
                AND Parent.IsOwnedByProfile = TRUE
                AND Parent.Profile.UserLicense.Name = 'Salesforce'
            ORDER BY Parent.Profile.Name
            LIMIT 1
        ];
        Assert.isFalse(perms.isEmpty(), 'Test setup needs a non-admin Salesforce profile with Lead edit access');
        return perms[0].Parent.ProfileId;
    }

    private static User newUser(String lastName, Id profileId, Boolean active) {
        String unique = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 12);
        return new User(
            FirstName = 'Test',
            LastName = lastName,
            Alias = unique.substring(0, 8),
            Email = 'laa.' + unique + '@example.com',
            Username = 'laa.' + unique + '@example.com.leadassign',
            ProfileId = profileId,
            IsActive = active,
            TimeZoneSidKey = 'Europe/Paris',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    private static User rep(String lastName) {
        return [SELECT Id, Username FROM User WHERE LastName = :lastName LIMIT 1];
    }

    private static Id queueId(String developerName) {
        return [SELECT Id FROM Group WHERE DeveloperName = :developerName AND Type = 'Queue' LIMIT 1].Id;
    }

    private static Lead_Assignment_Rule__mdt userRule(
        String devName,
        String industry,
        String country,
        String username,
        Integer priority
    ) {
        return rule(devName, industry, country, LeadAssignmentHandler.TYPE_USER, username, priority);
    }

    private static Lead_Assignment_Rule__mdt rule(
        String devName,
        String industry,
        String country,
        String assigneeType,
        String assignee,
        Integer priority
    ) {
        return new Lead_Assignment_Rule__mdt(
            DeveloperName = devName,
            Industry__c = industry,
            Country__c = country,
            Assignee_Type__c = assigneeType,
            Assignee__c = assignee,
            Priority__c = priority,
            Is_Active__c = true
        );
    }

    // Tech + France -> Tech rep, Finance (any country) -> Finance rep, else -> Default rep
    private static void useStandardRules() {
        LeadAssignmentHandler.rulesOverride = new List<Lead_Assignment_Rule__mdt>{
            userRule('Tech_France', 'Technology', 'France', rep(TECH_REP).Username, 10),
            userRule('Finance_Any', 'Finance', null, rep(FINANCE_REP).Username, 20),
            userRule('Default', null, null, rep(DEFAULT_REP).Username, 999)
        };
    }

    private static Lead newLead(String industry, String country) {
        return new Lead(LastName = 'Test', Company = 'Acme', Industry = industry, Country = country);
    }

    private static Id ownerOf(Lead lead) {
        return [SELECT OwnerId FROM Lead WHERE Id = :lead.Id].OwnerId;
    }

    // ------------------------------------------------------------------ tests

    @IsTest
    static void testHandlerAssignsAwayFromInsertingUser() {
        useStandardRules();
        Lead lead = newLead('Technology', 'France');
        insert lead;

        Id owner = ownerOf(lead);
        Assert.areNotEqual(UserInfo.getUserId(), owner, 'Without the handler the inserting user would own the Lead');
        Assert.areEqual(rep(TECH_REP).Id, owner, 'Tech + France lead should go to the Tech rep');
    }

    @IsTest
    static void testIndustryOnlyMatch() {
        useStandardRules();
        Lead lead = newLead('Finance', 'Canada');
        insert lead;

        Assert.areEqual(rep(FINANCE_REP).Id, ownerOf(lead), 'Finance lead (any country) should go to the Finance rep');
    }

    @IsTest
    static void testCatchAllWhenNoSpecificRuleMatches() {
        useStandardRules();
        Lead lead = newLead('Retail', 'Brazil');
        insert lead;

        Assert.areEqual(rep(DEFAULT_REP).Id, ownerOf(lead), 'Unmatched lead should fall through to the catch-all');
    }

    @IsTest
    static void testMoreSpecificRuleWinsOverLowerPriorityNumber() {
        // The catch-all and the industry-only rule have better (lower) priority
        // numbers, but the Industry + Country rule is more specific.
        LeadAssignmentHandler.rulesOverride = new List<Lead_Assignment_Rule__mdt>{
            userRule('Default', null, null, rep(DEFAULT_REP).Username, 1),
            userRule('Tech_Any', 'Technology', null, rep(FINANCE_REP).Username, 5),
            userRule('Tech_France', 'Technology', 'France', rep(TECH_REP).Username, 50)
        };
        Lead techFrance = newLead('Technology', 'France');
        Lead techSpain = newLead('Technology', 'Spain');
        insert new List<Lead>{ techFrance, techSpain };

        Assert.areEqual(rep(TECH_REP).Id, ownerOf(techFrance), 'Industry + Country rule should beat less specific rules');
        Assert.areEqual(rep(FINANCE_REP).Id, ownerOf(techSpain), 'Single-criterion rule should beat the catch-all');
    }

    @IsTest
    static void testPriorityBreaksTieWithinSameSpecificity() {
        LeadAssignmentHandler.rulesOverride = new List<Lead_Assignment_Rule__mdt>{
            userRule('Tech_Any', 'Technology', null, rep(FINANCE_REP).Username, 30),
            userRule('Any_France', null, 'France', rep(TECH_REP).Username, 20)
        };
        Lead lead = newLead('Technology', 'France');
        insert lead;

        Assert.areEqual(rep(TECH_REP).Id, ownerOf(lead), 'Lower Priority__c should win between equally specific rules');
    }

    @IsTest
    static void testUnknownUsernameIsSkippedWithoutError() {
        LeadAssignmentHandler.rulesOverride = new List<Lead_Assignment_Rule__mdt>{
            userRule('Tech_France', 'Technology', 'France', 'nobody.' + UserInfo.getOrganizationId() + '@example.invalid', 10),
            userRule('Default', null, null, rep(DEFAULT_REP).Username, 999)
        };
        Lead lead = newLead('Technology', 'France');
        insert lead;

        Assert.areEqual(rep(DEFAULT_REP).Id, ownerOf(lead), 'Rule with an unknown username should be skipped');
    }

    @IsTest
    static void testInactiveUserIsSkippedWithoutError() {
        LeadAssignmentHandler.rulesOverride = new List<Lead_Assignment_Rule__mdt>{
            userRule('Tech_France', 'Technology', 'France', rep(INACTIVE_REP).Username, 10),
            userRule('Default', null, null, rep(DEFAULT_REP).Username, 999)
        };
        Lead lead = newLead('Technology', 'France');
        insert lead;

        Assert.areEqual(rep(DEFAULT_REP).Id, ownerOf(lead), 'Rule pointing at an inactive user should be skipped');
    }

    @IsTest
    static void testOnlyUnresolvableRulesLeaveOwnerUntouched() {
        // Mirrors the shipped sample records if someone activates them unchanged.
        LeadAssignmentHandler.rulesOverride = new List<Lead_Assignment_Rule__mdt>{
            userRule('Default', null, null, 'REPLACE_WITH_USERNAME', 999),
            rule('Blank', null, null, LeadAssignmentHandler.TYPE_USER, null, 1)
        };
        Lead lead = newLead('Technology', 'France');
        insert lead;

        Assert.areEqual(UserInfo.getUserId(), ownerOf(lead), 'Insert should succeed and keep the inserting user as owner');
    }

    @IsTest
    static void testQueueAssignee() {
        LeadAssignmentHandler.rulesOverride = new List<Lead_Assignment_Rule__mdt>{
            rule('Tech_France', 'Technology', 'France', LeadAssignmentHandler.TYPE_QUEUE, LEAD_QUEUE, 10)
        };
        Lead lead = newLead('Technology', 'France');
        insert lead;

        Assert.areEqual(queueId(LEAD_QUEUE), ownerOf(lead), 'Lead should be assigned to the Lead queue');
    }

    @IsTest
    static void testQueueThatDoesNotSupportLeadIsSkipped() {
        LeadAssignmentHandler.rulesOverride = new List<Lead_Assignment_Rule__mdt>{
            rule('Tech_France', 'Technology', 'France', LeadAssignmentHandler.TYPE_QUEUE, CASE_ONLY_QUEUE, 10),
            userRule('Default', null, null, rep(DEFAULT_REP).Username, 999)
        };
        Lead lead = newLead('Technology', 'France');
        insert lead;

        Assert.areEqual(rep(DEFAULT_REP).Id, ownerOf(lead), 'A queue without Lead support should be skipped');
    }

    @IsTest
    static void testUpdateIgnoresIrrelevantFieldChanges() {
        useStandardRules();
        Lead lead = newLead('Technology', 'France');
        insert lead;

        // Point the Tech + France rule at a different rep: if the handler
        // re-ran on this update, the owner would change.
        LeadAssignmentHandler.rulesOverride = new List<Lead_Assignment_Rule__mdt>{
            userRule('Tech_France', 'Technology', 'France', rep(FINANCE_REP).Username, 10)
        };
        lead.LastName = 'Updated';
        update lead;

        Assert.areEqual(rep(TECH_REP).Id, ownerOf(lead), 'Changing an irrelevant field should not change the owner');
    }

    @IsTest
    static void testUpdateReassignsWhenIndustryChanges() {
        useStandardRules();
        Lead lead = newLead('Technology', 'France');
        insert lead;

        lead.Industry = 'Finance';
        update lead;

        Assert.areEqual(rep(FINANCE_REP).Id, ownerOf(lead), 'Changing industry should trigger a new assignment');
    }

    @IsTest
    static void testNoRulesLeavesOwnerUntouched() {
        LeadAssignmentHandler.rulesOverride = new List<Lead_Assignment_Rule__mdt>();
        Lead lead = newLead('Technology', 'France');
        insert lead;

        Assert.areEqual(UserInfo.getUserId(), ownerOf(lead), 'With no rules, owner should remain the inserting user');
    }

    @IsTest
    static void testCaseInsensitiveMatching() {
        useStandardRules();
        Lead lead = newLead('TECHNOLOGY', 'FRANCE');
        insert lead;

        Assert.areEqual(rep(TECH_REP).Id, ownerOf(lead), 'Matching should be case-insensitive');
    }

    @IsTest
    static void testBulkInsert200LeadsResolvesAssigneesOnce() {
        LeadAssignmentHandler.rulesOverride = new List<Lead_Assignment_Rule__mdt>{
            userRule('Tech_France', 'Technology', 'France', rep(TECH_REP).Username, 10),
            userRule('Finance_Any', 'Finance', null, rep(FINANCE_REP).Username, 20),
            rule('Retail_Queue', 'Retail', null, LeadAssignmentHandler.TYPE_QUEUE, LEAD_QUEUE, 30),
            userRule('Default', null, null, rep(DEFAULT_REP).Username, 999)
        };
        Map<String, Id> expectedOwnerByIndustry = new Map<String, Id>{
            'Technology' => rep(TECH_REP).Id,
            'Finance' => rep(FINANCE_REP).Id,
            'Retail' => queueId(LEAD_QUEUE),
            'Energy' => rep(DEFAULT_REP).Id
        };
        List<String> industries = new List<String>(expectedOwnerByIndustry.keySet());

        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            leads.add(newLead(industries[Math.mod(i, industries.size())], 'France'));
        }
        List<Lead> moreLeads = new List<Lead>{ newLead('Technology', 'France') };

        Test.startTest();
        insert leads;
        Integer queriesAfterFirstInsert = Limits.getQueries();
        insert moreLeads;
        Integer queriesAfterSecondInsert = Limits.getQueries();
        Test.stopTest();

        Assert.isTrue(
            queriesAfterFirstInsert <= 2,
            'Expected at most one User and one QueueSobject query for 200 leads, got ' + queriesAfterFirstInsert
        );
        Assert.areEqual(
            queriesAfterFirstInsert,
            queriesAfterSecondInsert,
            'Assignees should be cached for the rest of the transaction'
        );

        Map<Id, Lead> results = new Map<Id, Lead>([SELECT Industry, OwnerId FROM Lead WHERE Id IN :leads]);
        Assert.areEqual(200, results.size(), 'All 200 leads should be inserted');
        for (Lead l : results.values()) {
            Assert.areEqual(
                expectedOwnerByIndustry.get(l.Industry),
                l.OwnerId,
                'Wrong owner for a ' + l.Industry + ' lead'
            );
        }
        Assert.areEqual(rep(TECH_REP).Id, ownerOf(moreLeads[0]), 'Second insert should reuse the cached assignees');
    }
}
