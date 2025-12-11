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
            System.enqueueJob(new CaseInsightsQueueable(caseIds));
        }
    }

    public class CaseInsightsQueueable implements Queueable, Database.AllowsCallouts {
        private final List<Id> caseIds;

        public CaseInsightsQueueable(List<Id> caseIds) {
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

            for (Case caseRecord : casesToProcess) {
                if (caseRecord == null) {
                    continue;
                }
                sendAnalysisRequest(caseRecord);
            }
        }
    }

    @TestVisible
    private static void sendAnalysisRequest(Case caseRecord) {
        if (caseRecord == null) {
            return;
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:OpenAI/v1/responses');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer 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');
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
        } else {
            System.debug(LoggingLevel.WARN, 'OpenAI response could not be parsed for Case '
                + caseRecord.Id + ': ' + res.getBody());
        }
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
