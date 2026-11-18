// cspell:ignore graphql
// GitHub GraphQL mock of the rsshub image smoke test: one organization, one repository.
import { createServer } from 'node:http';

const token = process.env.MOCK_TOKEN ?? '';
const site = 'https://github.com/';
const repository = 'smoke-org/demo';
const published = '2026-01-01T00:00:00Z';
const rateLimit = { cost: 1, remaining: 4999, resetAt: '2026-01-01T01:00:00Z' };
let posts = 0;

const asset = (name, size) => ({
  id: `RA_${name}`,
  name,
  downloadUrl: `${site}${repository}/releases/download/v1.0.0/${name}`,
  size,
  contentType: 'application/vnd.android.package-archive',
  updatedAt: published,
});

const release = {
  id: 'RE_smoke',
  databaseId: 1,
  name: 'v1.0.0',
  tagName: 'v1.0.0',
  url: `${site}${repository}/releases/tag/v1.0.0`,
  isDraft: false,
  isPrerelease: false,
  createdAt: published,
  publishedAt: published,
  updatedAt: published,
  description: 'First release',
  descriptionHTML: '<p>First release</p>',
  releaseAssets: {
    pageInfo: { hasNextPage: false, endCursor: null },
    nodes: [asset('demo.apk', 1048576), asset('demo-debug.apk', 2048)],
  },
};

const repositoryNode = {
  id: 'R_smoke',
  nameWithOwner: repository,
  description: 'Smoke module',
  url: `${site}${repository}`,
  isFork: false,
  isArchived: false,
  isPrivate: false,
  releases: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [release] },
};

const notFound = (path) => ({ type: 'NOT_FOUND', path, message: 'Could not resolve' });

const ownerPage = (variables) => {
  if (variables.login !== 'smoke-org') {
    return { data: { owner: null, rateLimit }, errors: [notFound(['owner'])] };
  }
  const edge = { cursor: 'Y3Vyc29yOjE=', node: repositoryNode };
  const page = {
    pageInfo: { hasNextPage: false, endCursor: edge.cursor },
    edges: [edge],
  };
  return { data: { owner: { repositories: page }, rateLimit } };
};

const repositories = (variables) => {
  const data = { rateLimit };
  const errors = [];
  for (let index = 0; `o${index}` in variables; index++) {
    const name = `${variables[`o${index}`]}/${variables[`n${index}`]}`;
    data[`r${index}`] = name === repository ? repositoryNode : null;
    if (name !== repository) {
      errors.push(notFound([`r${index}`]));
    }
  }
  return errors.length > 0 ? { data, errors } : { data };
};

const answer = (query, variables) => {
  if (query.includes('query GithubReleasesOwnerPage')) {
    return ownerPage(variables);
  }
  if (query.includes('query GithubReleasesRepositories')) {
    return repositories(variables);
  }
  return null;
};

const server = createServer((request, response) => {
  if (request.method === 'GET' && request.url === '/count') {
    response.writeHead(200, { 'content-type': 'text/plain' });
    response.end(String(posts));
    return;
  }
  if (request.method !== 'POST' || request.url !== '/graphql') {
    response.writeHead(404).end();
    return;
  }
  posts++;
  if (request.headers.authorization !== `bearer ${token}`) {
    response.writeHead(401).end();
    return;
  }
  let body = '';
  request.setEncoding('utf8');
  request.on('data', (chunk) => {
    body += chunk;
  });
  request.on('end', () => {
    const { query, variables } = JSON.parse(body);
    const result = answer(query, variables);
    response.writeHead(result ? 200 : 400, { 'content-type': 'application/json' });
    response.end(JSON.stringify(result ?? { message: 'unexpected query' }));
  });
});

server.listen(8080, '0.0.0.0');
