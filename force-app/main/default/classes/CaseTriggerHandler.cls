public with sharing class CaseTriggerHandler {
    public static void handleAfterInsert(List<Case> newCases) {
        if (newCases == null || newCases.isEmpty()) {
            return;
        }
        
        List<Id> caseIds = new List<Id>();
        for (Case caseRecord : newCases) {
            if (caseRecord != null && caseRecord.Id != null) {
                caseIds.add(caseRecord.Id);
            }
        }
        
        if (!caseIds.isEmpty()) {
            System.enqueueJob(new CaseAnalysisQueueable(caseIds));
        }
    }
    
    public class CaseAnalysisQueueable implements Queueable, Database.AllowsCallouts {
        private final List<Id> caseIds;
        
        public CaseAnalysisQueueable(List<Id> caseIds) {
            this.caseIds = caseIds != null ? new List<Id>(caseIds) : new List<Id>();
        }
        
        public void execute(QueueableContext context) {
            if (caseIds.isEmpty()) {
                return;
            }
            
            List<Case> casesToProcess = [
                SELECT Id, Subject, Description
                FROM Case
                WHERE Id IN :caseIds
            ];
            
            List<Case_Analysis__c> analysesToInsert = new List<Case_Analysis__c>();
            List<Case> casesToUpdate = new List<Case>();
            for (Case caseRecord : casesToProcess) {
                if (caseRecord == null) {
                    continue;
                }
                AnalysisResult result = sendOpenAIRequest(caseRecord);
                if (result == null) {
                    continue;
                }
                if (result.analysisRecord != null) {
                    analysesToInsert.add(result.analysisRecord);
                }
                if (result.caseUpdate != null) {
                    casesToUpdate.add(result.caseUpdate);
                }
            }
            
            if (!analysesToInsert.isEmpty()) {
                insert analysesToInsert;
            }
            if (!casesToUpdate.isEmpty()) {
                update casesToUpdate;
            }
        }
    }
    
    @TestVisible
    private static AnalysisResult sendOpenAIRequest(Case caseRecord) {
        if (caseRecord == null) {
            return null;
        }
        
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:OpenAI/v1/responses');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(buildRequestBody(caseRecord));
        
        HttpResponse res = new Http().send(req);
        Map<String, Object> analysis = parseResponse(res.getBody());
        if (analysis != null) {
            String priority = (String) analysis.get('priority');
            String severity = (String) analysis.get('severity');
            String complexity = (String) analysis.get('complexity');
            String summary = (String) analysis.get('summary');
            List<Object> resolutionSteps = (List<Object>) analysis.get('resolution_steps');
            String sentiment = (String) analysis.get('sentiment');
            List<Object> keywords = (List<Object>) analysis.get('keywords');
            
            List<String> resolutionStepsStr = asStringList(resolutionSteps);
            List<String> keywordsStr = asStringList(keywords);
            
            System.debug(LoggingLevel.INFO,
            'OpenAI analysis for Case ' + caseRecord.Id + ': '
                + 'priority=' + priority
                + ', severity=' + severity
                + ', complexity=' + complexity
                + ', summary=' + summary
                + ', resolution_steps=' + (resolutionStepsStr != null ? String.join(resolutionStepsStr, '; ') : null)
                + ', sentiment=' + sentiment
                + ', keywords=' + (keywordsStr != null ? String.join(keywordsStr, ', ') : null)
                );
            Case_Analysis__c analysisRecord = new Case_Analysis__c();
            analysisRecord.Case__c = caseRecord.Id;
            analysisRecord.Sentiment__c = sentiment;
            analysisRecord.Raw_LLM_Response__c = res.getBody();
            AnalysisResult result = new AnalysisResult();
            result.analysisRecord = analysisRecord;
            result.caseUpdate = buildCaseUpdate(caseRecord.Id,priority,resolutionStepsStr,complexity,summary);
            return result;
        }  else {
            System.debug(LoggingLevel.WARN, 'OpenAI response could not be parsed for Case ' + caseRecord.Id + ': ' + res.getBody());
        }
        return null;
    }
    
    @TestVisible
    private static Case buildCaseUpdate(Id caseId, String priority, List<String> resolution_steps, String complexity, String summary) {
        Case caseUpdate = new Case(Id = caseId);
        Boolean hasChanges = false;
        if (!String.isBlank(priority)) {
            caseUpdate.Predicted_Priority__c = priority;
            hasChanges = true;
        }
        if (!String.isBlank(complexity)) {
            caseUpdate.put('Predicted_Complexity__c', complexity);
            hasChanges = true;
        }
        if (resolution_steps != null && !resolution_steps.isEmpty()) {
            caseUpdate.put('AI_Resolution_Steps__c', String.join(resolution_steps, '; '));
            hasChanges = true;
        }
        if (!String.isBlank(summary)) {
            caseUpdate.put('AI_Suggested_Summary__c', summary);
            hasChanges = true;
        }
        return hasChanges ? caseUpdate : null;
    }
    
    private class AnalysisResult {
        Case_Analysis__c analysisRecord;
        Case caseUpdate;
    }
    
    @TestVisible
    private static String buildRequestBody(Case caseRecord) {
        String subject = String.isBlank(caseRecord.Subject) ? 'Unknown' : caseRecord.Subject;
        String description = String.isBlank(caseRecord.Description)
            ? 'Description not provided.'
            : caseRecord.Description;
        
        Map<String, Object> payload = new Map<String, Object>();
        payload.put('model', 'gpt-4.1-mini');
        payload.put(
            'input',
        'Analyze the following Case and return STRICT JSON with these fields: '
            + 'priority, complexity, summary, resolution_steps, sentiment, keywords. '
            + 'Return ONLY JSON. Case Subject: ' + subject + '. Case Description: ' + description
            );
        
        return JSON.serialize(payload);
    }
    
    @TestVisible
    private static Map<String, Object> parseResponse(String responseBody) {
        if (String.isBlank(responseBody)) {
            return null;
        }
        
        try {
            Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            List<Object> outputs = (List<Object>) responseMap.get('output');
            
            if (outputs == null || outputs.isEmpty()) {
                return null;
            }
            
            for (Object outputObj : outputs) {
                Map<String, Object> outputEntry = (Map<String, Object>) outputObj;
                List<Object> contents = (List<Object>) outputEntry.get('content');
                
                if (contents == null || contents.isEmpty()) {
                    continue;
                }
                
                for (Object contentObj : contents) {
                    Map<String, Object> contentEntry = (Map<String, Object>) contentObj;
                    String type = (String) contentEntry.get('type');
                    
                    if ('output_text'.equals(type)) {
                        String textPayload = (String) contentEntry.get('text');
                        String jsonBlock = extractJsonSnippet(textPayload);
                        if (!String.isBlank(jsonBlock)) {
                            return (Map<String, Object>) JSON.deserializeUntyped(jsonBlock);
                        }
                    }
                }
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Failed to parse OpenAI response: ' + ex.getMessage());
        }
        
        return null;
    }
    
    @TestVisible
    private static String extractJsonSnippet(String textPayload) {
        if (String.isBlank(textPayload)) {
            return null;
        }
        
        Integer start = textPayload.indexOf('{');
        Integer endOf = textPayload.lastIndexOf('}');
        if (start != -1 && endOf != -1 && endOf > start) {
            return textPayload.substring(start, endOf + 1);
        }
        return textPayload;
    }
    
    @TestVisible
    private static List<String> asStringList(List<Object> rawValues) {
        if (rawValues == null || rawValues.isEmpty()) {
            return null;
        }
        
        List<String> results = new List<String>();
        for (Object value : rawValues) {
            results.add(value != null ? String.valueOf(value) : null);
        }
        
        return results;
    }
}
