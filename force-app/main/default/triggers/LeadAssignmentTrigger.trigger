trigger LeadAssignmentTrigger on Lead(before insert, before update) {
  LeadAssignmentHandler.handle(Trigger.new, Trigger.oldMap);
}
