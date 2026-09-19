// In-memory data store for the Claims backend (replaces the previous MySQL-backed
// implementation). Same public function signatures as before, so main.bal is
// unaffected - only the storage mechanism changed.
//
// All mutable state is kept in a single isolated record (dataStore) so that
// every read/write goes through exactly one lock, satisfying the "one isolated
// root per lock" rule while still letting claim updates and their journey
// steps change together.

import ballerina/time;

// ---------------------------------------------------------------------------
// Seed data
// ---------------------------------------------------------------------------

final readonly & Customer[] seedCustomers = [
    {customerId: "CUST-2001", name: "Amara Okafor", email: "amara.okafor@example.com", phone: "+27-11-555-0101"},
    {customerId: "CUST-2002", name: "Thabo Nkosi", email: "thabo.nkosi@example.com", phone: "+27-11-555-0102"},
    {customerId: "CUST-2003", name: "Lindiwe Dlamini", email: "lindiwe.dlamini@example.com", phone: "+27-11-555-0103"}
];

type SeedClaim record {|
    string claimId;
    string customerId;
    string claimType;
    string description;
    decimal amount;
    string status;
    string[] documentsReceived;
    string[] missingDocuments;
|};

final readonly & SeedClaim[] seedClaimList = [
    {
        claimId: "CLM-1041",
        customerId: "CUST-2001",
        claimType: "Water damage",
        description: "Minor water damage to kitchen ceiling following a burst pipe.",
        amount: 450.00,
        status: "READY",
        documentsReceived: ["incident_report.pdf", "photos.zip"],
        missingDocuments: []
    },
    {
        claimId: "CLM-1042",
        customerId: "CUST-2002",
        claimType: "Water damage",
        description: "Water damage to living room flooring and furniture after storm flooding.",
        amount: 2500.00,
        status: "MISSING_DOCUMENTS",
        documentsReceived: ["incident_report.pdf"],
        missingDocuments: ["proof_of_ownership.pdf", "repair_estimate.pdf"]
    },
    {
        claimId: "CLM-1043",
        customerId: "CUST-2003",
        claimType: "Accidental damage",
        description: "Accidental damage to a laptop dropped during a house move.",
        amount: 800.00,
        status: "READY",
        documentsReceived: ["incident_report.pdf", "purchase_receipt.pdf"],
        missingDocuments: []
    }
];

// Kept for resetClaim, which restores a demo claim to this exact seed state.
final readonly & map<SeedClaim> seedClaims = {
    "CLM-1041": seedClaimList[0],
    "CLM-1042": seedClaimList[1],
    "CLM-1043": seedClaimList[2]
};

// ---------------------------------------------------------------------------
// In-memory state - a single isolated root so every access uses one lock
// ---------------------------------------------------------------------------

type DataStore record {|
    map<Claim> claimsById;
    map<Customer> customersById;
    map<JourneyStep[]> journeyStepsByClaim;
    int nextJourneyStepId;
|};

isolated DataStore dataStore = {
    claimsById: {},
    customersById: {},
    journeyStepsByClaim: {},
    nextJourneyStepId: 1
};

isolated function timestampNow() returns string => time:utcToString(time:utcNow());

isolated function buildStep(int id, string claimId, string stepName, string status, string? detail)
        returns JourneyStep => {
    id,
    claimId,
    stepName,
    status,
    detail,
    occurredAt: timestampNow()
};

isolated function buildInitialJourneySteps(SeedClaim seed, int startId) returns [JourneyStep[], int] {
    JourneyStep[] steps = [];
    int id = startId;
    steps.push(buildStep(id, seed.claimId, "Claim received", "DONE", "Claim submitted by customer"));
    id += 1;
    steps.push(buildStep(id, seed.claimId, "Claim validated", "DONE", "All required fields present"));
    id += 1;
    if seed.missingDocuments.length() > 0 {
        steps.push(buildStep(id, seed.claimId, "Claim data retrieved", "DONE", "Claim and customer data loaded"));
        id += 1;
        steps.push(buildStep(id, seed.claimId, "Missing documents identified", "DONE",
                string:'join(", ", ...seed.missingDocuments) + " missing"));
        id += 1;
        steps.push(buildStep(id, seed.claimId, "Documents requested", "DONE", "Notification sent to customer (mock)"));
        id += 1;
    }
    return [steps, id];
}

isolated function seedClaimToClaim(SeedClaim seed) returns Claim => {
    claimId: seed.claimId,
    customerId: seed.customerId,
    claimType: seed.claimType,
    description: seed.description,
    amount: seed.amount,
    status: seed.status,
    documentsReceived: seed.documentsReceived.clone(),
    missingDocuments: seed.missingDocuments.clone(),
    decision: (),
    decisionReason: (),
    paymentStatus: "NOT_STARTED",
    createdAt: timestampNow(),
    updatedAt: timestampNow()
};

function init() {
    lock {
        foreach Customer customer in seedCustomers {
            dataStore.customersById[customer.customerId] = customer.clone();
        }
        int nextId = dataStore.nextJourneyStepId;
        foreach SeedClaim seed in seedClaimList {
            dataStore.claimsById[seed.claimId] = seedClaimToClaim(seed);
            [JourneyStep[], int] result = buildInitialJourneySteps(seed, nextId);
            dataStore.journeyStepsByClaim[seed.claimId] = result[0];
            nextId = result[1];
        }
        dataStore.nextJourneyStepId = nextId;
    }
}

// ---------------------------------------------------------------------------
// Public data access functions (same signatures as the previous MySQL version)
// ---------------------------------------------------------------------------

public function getAllClaims() returns Claim[]|error {
    lock {
        return dataStore.claimsById.toArray().clone();
    }
}

public function getClaim(string claimId) returns Claim|error? {
    lock {
        Claim? claim = dataStore.claimsById[claimId];
        if claim is () {
            return ();
        }
        return claim.clone();
    }
}

public function getCustomer(string customerId) returns Customer|error? {
    lock {
        Customer? customer = dataStore.customersById[customerId];
        if customer is () {
            return ();
        }
        return customer.clone();
    }
}

public function getJourneySteps(string claimId) returns JourneyStep[]|error {
    lock {
        JourneyStep[]? steps = dataStore.journeyStepsByClaim[claimId];
        if steps is () {
            return [];
        }
        return steps.clone();
    }
}

public function addJourneyStep(string claimId, string stepName, string status, string? detail = ()) returns error? {
    lock {
        int id = dataStore.nextJourneyStepId;
        dataStore.nextJourneyStepId += 1;
        JourneyStep step = buildStep(id, claimId, stepName, status, detail);
        JourneyStep[] steps = dataStore.journeyStepsByClaim[claimId] ?: [];
        steps.push(step);
        dataStore.journeyStepsByClaim[claimId] = steps;
    }
}

public function requestDocuments(string claimId, string[] missingDocuments) returns error? {
    string[] missingDocumentsCopy = missingDocuments.clone();
    lock {
        Claim? existing = dataStore.claimsById[claimId];
        if existing is () {
            return error(string `Claim ${claimId} not found`);
        }
        Claim updated = existing.clone();
        updated.status = "MISSING_DOCUMENTS";
        updated.missingDocuments = missingDocumentsCopy.clone();
        updated.updatedAt = timestampNow();
        dataStore.claimsById[claimId] = updated;

        int id = dataStore.nextJourneyStepId;
        dataStore.nextJourneyStepId += 1;
        JourneyStep step1 = buildStep(id, claimId, "Documents requested", "DONE",
                "Notification sent to customer (mock)");
        id = dataStore.nextJourneyStepId;
        dataStore.nextJourneyStepId += 1;
        JourneyStep step2 = buildStep(id, claimId, "Waiting for customer", "ACTIVE", ());

        JourneyStep[] steps = dataStore.journeyStepsByClaim[claimId] ?: [];
        steps.push(step1);
        steps.push(step2);
        dataStore.journeyStepsByClaim[claimId] = steps;
    }
}

public function documentsReceived(string claimId, string[] documents) returns error? {
    string[] documentsCopy = documents.clone();
    lock {
        Claim? existing = dataStore.claimsById[claimId];
        if existing is () {
            return error(string `Claim ${claimId} not found`);
        }
        string[] merged = existing.documentsReceived.clone();
        string[] documentsInLock = documentsCopy.clone();
        foreach string doc in documentsInLock {
            if merged.indexOf(doc) is () {
                merged.push(doc);
            }
        }
        Claim updated = existing.clone();
        updated.documentsReceived = merged;
        updated.missingDocuments = [];
        updated.status = "READY";
        updated.updatedAt = timestampNow();
        dataStore.claimsById[claimId] = updated;

        // Close out the ACTIVE "Waiting for customer" step opened by requestDocuments,
        // otherwise the portal timeline shows the claim as still waiting long after
        // it has been decided and paid.
        JourneyStep[] steps = dataStore.journeyStepsByClaim[claimId] ?: [];
        JourneyStep[] updatedSteps = [];
        foreach JourneyStep step in steps {
            JourneyStep next = step.clone();
            if next.stepName == "Waiting for customer" && next.status == "ACTIVE" {
                next.status = "DONE";
            }
            updatedSteps.push(next);
        }
        int id = dataStore.nextJourneyStepId;
        dataStore.nextJourneyStepId += 1;
        updatedSteps.push(buildStep(id, claimId, "Documents received", "DONE",
                "Customer submitted the requested documents"));
        dataStore.journeyStepsByClaim[claimId] = updatedSteps;
    }
}

public function submitDecision(string claimId, string decision, string? reason = ()) returns error? {
    lock {
        Claim? existing = dataStore.claimsById[claimId];
        if existing is () {
            return error(string `Claim ${claimId} not found`);
        }
        Claim updated = existing.clone();
        updated.decision = decision;
        updated.decisionReason = reason;
        updated.status = "DECIDED";
        updated.updatedAt = timestampNow();
        dataStore.claimsById[claimId] = updated;

        int id = dataStore.nextJourneyStepId;
        dataStore.nextJourneyStepId += 1;
        string detail = reason is () ? "Decision: " + decision : string `Decision: ${decision} - ${reason}`;
        JourneyStep[] steps = dataStore.journeyStepsByClaim[claimId] ?: [];
        steps.push(buildStep(id, claimId, "Claim decision recorded", "DONE", detail));
        dataStore.journeyStepsByClaim[claimId] = steps;
    }
}

// Hands the claim to a human adjuster. Terminal as far as the automated flow is
// concerned: nothing downstream reads ESCALATED, it simply stops the agent.
public function escalateClaim(string claimId, string reason, string summary) returns error? {
    lock {
        Claim? existing = dataStore.claimsById[claimId];
        if existing is () {
            return error(string `Claim ${claimId} not found`);
        }
        Claim updated = existing.clone();
        updated.status = "ESCALATED";
        updated.decisionReason = summary;
        updated.updatedAt = timestampNow();
        dataStore.claimsById[claimId] = updated;

        int id = dataStore.nextJourneyStepId;
        dataStore.nextJourneyStepId += 1;
        JourneyStep step1 = buildStep(id, claimId, "Escalated to adjuster", "DONE",
                string `${reason}: ${summary}`);
        id = dataStore.nextJourneyStepId;
        dataStore.nextJourneyStepId += 1;
        JourneyStep step2 = buildStep(id, claimId, "Awaiting adjuster review", "ACTIVE", ());

        JourneyStep[] steps = dataStore.journeyStepsByClaim[claimId] ?: [];
        steps.push(step1);
        steps.push(step2);
        dataStore.journeyStepsByClaim[claimId] = steps;
    }
}

public function processPayment(string claimId) returns error? {
    lock {
        Claim? existing = dataStore.claimsById[claimId];
        if existing is () {
            return error(string `Claim ${claimId} not found`);
        }
        Claim updated = existing.clone();
        updated.paymentStatus = "PAID";
        updated.status = "PAID";
        updated.updatedAt = timestampNow();
        dataStore.claimsById[claimId] = updated;

        int id = dataStore.nextJourneyStepId;
        dataStore.nextJourneyStepId += 1;
        JourneyStep step1 = buildStep(id, claimId, "Payment processed", "DONE", ());
        id = dataStore.nextJourneyStepId;
        dataStore.nextJourneyStepId += 1;
        JourneyStep step2 = buildStep(id, claimId, "Customer notified", "DONE",
                "Notification sent to customer (mock)");

        JourneyStep[] steps = dataStore.journeyStepsByClaim[claimId] ?: [];
        steps.push(step1);
        steps.push(step2);
        dataStore.journeyStepsByClaim[claimId] = steps;
    }
}

public function resetClaim(string claimId) returns error? {
    readonly & SeedClaim? seed = seedClaims[claimId];
    if seed is () {
        return error(string `Reset is only supported for the sample claims: ${seedClaims.keys().toBalString()}`);
    }
    Claim resetClaimValue = seedClaimToClaim(seed);
    lock {
        dataStore.claimsById[claimId] = resetClaimValue.clone();
        int nextId = dataStore.nextJourneyStepId;
        [JourneyStep[], int] result = buildInitialJourneySteps(seed, nextId);
        dataStore.journeyStepsByClaim[claimId] = result[0];
        dataStore.nextJourneyStepId = result[1];
    }
}
