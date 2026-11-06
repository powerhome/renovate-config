import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
const root = process.env.RENOVATE_ROOT;
assert.ok(root, 'Set RENOVATE_ROOT to the installed renovate package directory');
const load = p => import(pathToFileURL(`${root}/dist/${p}`));
const {GlobalConfig} = await load('config/global.js');
const {getConfig} = await load('config/defaults.js');
const {applyPackageRules} = await load('util/package-rules/index.js');
const {lookupUpdates} = await load('workers/repository/process/lookup/index.js');
const {getDatasourceFor} = await load('modules/datasource/common.js');
const {resetCache} = await load('util/cache/repository/index.js');
const {extractPackageFile} = await load('modules/manager/dockerfile/extract.js');
const {getExpression} = await load('util/jsonata.js');
const {api: dockerVersioning} = await load('modules/versioning/docker/index.js');
GlobalConfig.set({localDir:'/tmp',cacheDir:'/tmp/nip-publication-check-cache'});
const preset = JSON.parse(readFileSync(new URL('../publication-age-containers.json', import.meta.url)));
let snapshot;
getDatasourceFor('custom.nip-publication').http.getJsonUnchecked = async () => ({body:snapshot});
const digest = c => `sha256:${c.repeat(64)}`;
const old = '2025-01-01T00:00:00Z';
const normalize = getExpression(preset.customDatasources['nip-publication'].transformTemplates[1]);
for (const values of [
  ['0.9.2', 'v0.9.2', '00.09.02'],
  ['0.9.2', '0.09.2-', 'v0.9.2-'],
  ['1.2-alpine', 'v1.2-alpine', '01.02-alpine'],
  ['1.2rc1', 'v1.2rc1'],
  ['1.2-alpine-x', 'v01.02-alpine-x'],
]) {
  assert.ok(values.every(value => dockerVersioning.equals(value, values[0])));
  const {releases} = await normalize.evaluate({releases:values.map((version, i) => ({
    version, digest:digest(String(i)), releaseTimestamp:i === 1 ? '2026-01-01T00:00:00Z' : old,
  }))});
  assert.ok(releases.every(r => r.releaseTimestamp === '2026-01-01T00:00:00.000Z'));
  assert.deepEqual(releases.map(r => r.version), values);
  assert.deepEqual(releases.map(r => r.digest), values.map((_, i) => digest(String(i))));
}
for (const values of [['1.2', '1.2.0'], ['1.2-alpine', '1.2-debian'], ['1.2rc1', '1.2rc2']]) {
  assert.ok(!dockerVersioning.equals(...values));
  const {releases} = await normalize.evaluate({releases:values.map((version, i) => ({
    version, releaseTimestamp:i ? '2026-01-01T00:00:00Z' : old,
  }))});
  assert.notEqual(releases[0].releaseTimestamp, releases[1].releaseTimestamp);
}
async function config(packageName, currentValue, extra = {}) {
  const extracted = extractPackageFile(`FROM ${packageName}:${currentValue}@${digest('a')}\n`, 'Dockerfile', {});
  const dep = extracted.deps[0];
  assert.equal(dep.packageName ?? dep.depName, packageName);
  const cfg = await applyPackageRules({...getConfig(), ...dep, manager:'dockerfile', packageFile:'Dockerfile', packageName,
    minimumReleaseAge:'3 days', minimumReleaseAgeBehaviour:'timestamp-optional', internalChecksFilter:'strict',
    pinDigests:true, rangeStrategy:'pin', customDatasources:preset.customDatasources, packageRules:preset.packageRules,
    ...extra}, 'fixture');
  return cfg;
}
async function lookup(cfg, releases, extra = {}) {
  resetCache();
  snapshot = {schemaVersion:1, packageName:cfg.packageName, collectedAt:new Date().toISOString(), releases, ...extra};
  const {val, err} = (await lookupUpdates(cfg)).unwrap();
  if (err) throw err;
  return val;
}
const cfg = await config('ghcr.io/astral-sh/uv', '0.9.2');
assert.equal(cfg.datasource, 'custom.nip-publication');
assert.equal(cfg.versioning, 'docker');
const releases = [
 {version:'0.9.2', digest:digest('b'), releaseTimestamp:old},
 {version:'0.9.3', digest:digest('c'), releaseTimestamp:old},
];
const stable = await lookup(cfg, releases);
assert.ok(stable.updates.some(u => u.newValue === '0.9.3' && u.newDigest === digest('c') && !u.pendingChecks));
assert.ok(stable.updates.some(u => u.updateType === 'digest' && u.newDigest === digest('b') && !u.pendingChecks));
const young = await lookup(cfg, releases.map(r => ({...r,releaseTimestamp:new Date().toISOString()})));
assert.ok(young.updates.length > 0);
assert.ok(young.updates.every(u => u.pendingChecks));
const missing = await lookup(cfg, releases.map(({releaseTimestamp,...r}) => r));
assert.ok(missing.updates.length > 0);
assert.ok(missing.updates.every(u => u.pendingChecks));
// Docker considers v-prefixed and zero-padded numeric tags equal. Every exact
// digest must wait for the newest publication in its equivalent-version group.
for (const alias of ['v0.9.2', '00.09.02', '0.09.2-']) {
  const collisionReleases = [
    {version:alias, digest:digest('e'), releaseTimestamp:old},
    {version:'0.9.2', digest:digest('b'), releaseTimestamp:new Date().toISOString()},
    releases[1],
  ];
  for (const ordered of [collisionReleases, [...collisionReleases].reverse()]) {
    const collision = await lookup(cfg, ordered);
    assert.ok(collision.updates.some(u => u.updateType === 'digest' && u.newDigest === digest('b') && u.pendingChecks));
    assert.ok(collision.updates.some(u => u.newValue === '0.9.3' && !u.pendingChecks));
    const missingCollision = await lookup(cfg, ordered.map(r => r.version === alias ? {version:r.version,digest:r.digest} : {...r,releaseTimestamp:old}));
    assert.ok(missingCollision.updates.some(u => u.updateType === 'digest' && u.pendingChecks));
  }
}
const stale = await lookup(cfg, releases, {collectedAt:old});
assert.equal(stale.updates.length, 0);
assert.ok(stale.warnings.length > 0);
const identityMismatch = await lookup(cfg, releases, {packageName:'ghcr.io/other/image'});
assert.equal(identityMismatch.updates.length, 0);
const nonrootCfg = await config('gcr.io/distroless/static-debian12', 'nonroot');
const nonroot = await lookup(nonrootCfg, [{version:'nonroot',digest:digest('d'),releaseTimestamp:old}]);
assert.ok(nonroot.updates.some(u => u.updateType === 'digest' && u.newValue === 'nonroot' && u.newDigest === digest('d') && !u.pendingChecks));
const youngNonroot = await lookup(nonrootCfg, [{version:'nonroot',digest:digest('d'),releaseTimestamp:new Date().toISOString()}]);
assert.ok(youngNonroot.updates.some(u => u.updateType === 'digest' && u.pendingChecks));
// A numeric-looking sibling must not lend its old timestamp to the exact alias.
const nonrootCollisionReleases = [
  {version:'0nonroot',digest:digest('e'),releaseTimestamp:old},
  {version:'nonroot',digest:digest('d'),releaseTimestamp:new Date().toISOString()},
];
for (const ordered of [nonrootCollisionReleases, [...nonrootCollisionReleases].reverse()]) {
  const collision = await lookup(nonrootCfg, ordered);
  assert.ok(collision.updates.some(u => u.updateType === 'digest' && u.newValue === 'nonroot' && u.newDigest === digest('d') && u.pendingChecks));
}

const exempt = await config('ghcr.io/powerhome/example','1.0.0');
assert.equal(exempt.datasource,'docker');
const nativeDocker = getDatasourceFor('docker');
let nativeDigestLookups = 0;
nativeDocker.getReleases = async () => ({releases:[]});
nativeDocker.getDigest = async () => { nativeDigestLookups++; return digest('f'); };
const latestCfg = await config('ghcr.io/astral-sh/uv', 'latest');
assert.equal(latestCfg.datasource, 'docker');
resetCache();
const latest = (await lookupUpdates(latestCfg)).unwrap().val;
assert.ok(nativeDigestLookups > 0);
assert.ok(latest.updates.some(u => u.updateType === 'digest' && u.newDigest === digest('f')));
for (const alias of ['stable', 'alpine', 'nonroot', '123abcd']) {
  assert.equal((await config('ghcr.io/astral-sh/uv', alias)).datasource, 'docker');
}
for (const extra of [
  {registryUrls:['https://mirror.example']},
  {defaultRegistryUrls:['https://mirror.example']},
  {additionalRegistryUrls:['https://mirror.example']},
]) {
  assert.equal((await config('ghcr.io/astral-sh/uv','0.9.2',extra)).datasource,'docker');
}
assert.equal((await config('ghcr.io/astral-sh/uv','0.9.2',{registryUrls:['https://ghcr.io/']})).datasource,'custom.nip-publication');
console.log('Container extraction, exact digest lookup, equivalent-tag age gating, stale/mismatched evidence, native moving aliases, nonroot alias and first-party scope checks passed.');
