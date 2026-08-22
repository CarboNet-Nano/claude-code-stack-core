export function resolveScope(portfolioName, fallbackConfig) {
  const portfolio = fallbackConfig.portfolios?.[portfolioName];
  if (!portfolio) {
    return [];
  }
  return [...(portfolio.members || [])];
}

export function discoverSuggestions(portfolioName, ghProperties, fallbackConfig) {
  const configScope = new Set(resolveScope(portfolioName, fallbackConfig));

  const suggestions = [];
  for (const [repo, props] of Object.entries(ghProperties)) {
    const portfolioValue = props["cn-portfolio"];
    if (portfolioValue === portfolioName && !configScope.has(repo)) {
      suggestions.push(repo);
    }
  }

  return suggestions;
}

export async function fetchGhProperties(execFile, repos) {
  const result = {};

  for (const repo of repos) {
    try {
      const { stdout } = await execFile("gh", ["api", `repos/${repo}/properties/values`]);
      const data = JSON.parse(stdout);
      result[repo] = data;
    } catch {
      // gh failure → skip this repo, return what we have
    }
  }

  return result;
}
