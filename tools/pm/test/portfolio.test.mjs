import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveScope, discoverSuggestions, fetchGhProperties } from "../src/portfolio.mjs";

const mockConfig = {
  portfolios: {
    carbonet: {
      pace: "balanced",
      members: [
        "CarboNet-Nano/carbonet-provisioner",
        "CarboNet-Nano/carbonet-app-template",
        "get-lade/claude-code-stack"
      ]
    },
    lade: {
      pace: "aggressive",
      members: [
        "get-lade/lade-guardian",
        "get-lade/lade-team"
      ]
    }
  }
};

test("REQ-100: resolveScope returns exactly config members", () => {
  const scope = resolveScope("carbonet", mockConfig);
  assert.deepEqual(scope, [
    "CarboNet-Nano/carbonet-provisioner",
    "CarboNet-Nano/carbonet-app-template",
    "get-lade/claude-code-stack"
  ]);
});

test("REQ-100: discoverSuggestions finds repos with matching property absent from config", () => {
  const ghProps = {
    "CarboNet-Nano/carbonet-provisioner": { "cn-portfolio": "carbonet" },
    "CarboNet-Nano/carbonet-app-template": { "cn-portfolio": "carbonet" },
    "get-lade/claude-code-stack": { "cn-portfolio": "carbonet" },
    "CarboNet-Nano/carbonet-service": { "cn-portfolio": "carbonet" }  // matches but not in config
  };
  const suggestions = discoverSuggestions("carbonet", ghProps, mockConfig);
  assert.deepEqual(suggestions, ["CarboNet-Nano/carbonet-service"]);
});

test("REQ-100: config-authoritative scope — gh property cannot add repos", () => {
  const ghProps = {
    "CarboNet-Nano/carbonet-provisioner": { "cn-portfolio": "carbonet" },
    "CarboNet-Nano/carbonet-app-template": { "cn-portfolio": "carbonet" },
    "get-lade/claude-code-stack": { "cn-portfolio": "carbonet" },
    "CarboNet-Nano/carbonet-service": { "cn-portfolio": "carbonet" },  // suggests but doesn't add
    "unknown/repo": { "cn-portfolio": "carbonet" }                       // spoofed claim
  };
  const scope = resolveScope("carbonet", mockConfig);
  assert(!scope.includes("CarboNet-Nano/carbonet-service"));
  assert(!scope.includes("unknown/repo"));
  assert.equal(scope.length, 3);
});

test("REQ-100: two portfolios disjoint", () => {
  const carbonetScope = resolveScope("carbonet", mockConfig);
  const ladeScope = resolveScope("lade", mockConfig);
  const carbonetSet = new Set(carbonetScope);
  const ladeSet = new Set(ladeScope);

  for (const repo of carbonetSet) {
    assert(!ladeSet.has(repo), `Repo ${repo} should not be in both portfolios`);
  }
});

test("REQ-100: gh-failure results in empty suggestions, scope unchanged", async () => {
  const mockExecFile = async (cmd, args) => {
    throw new Error("gh api failed");
  };

  const ghProps = await fetchGhProperties(mockExecFile, ["CarboNet-Nano/carbonet-provisioner"]);
  assert.deepEqual(ghProps, {});

  const suggestions = discoverSuggestions("carbonet", ghProps, mockConfig);
  assert.deepEqual(suggestions, []);

  const scope = resolveScope("carbonet", mockConfig);
  assert.equal(scope.length, 3);  // scope unchanged
});
