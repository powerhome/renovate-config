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
GlobalConfig.set({localDir:'/tmp',cacheDir:'/tmp/nip-publication-check-cache'});
const preset = JSON.parse(readFileSync(new URL('../publication-age-containers.json', import.meta.url)));
let snapshot;
getDatasourceFor('custom.nip-publication').http.getJsonUnchecked = async () => ({body:snapshot});
const digest = c => `sha256:${c.repeat(64)}`;
const old = '2025-01-01T00:00:00Z';
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
assert.ok(missing.updates.every(u => u.pendingChecks));
const stale = await lookup(cfg, releases, {collectedAt:old});
assert.equal(stale.updates.length, 0);
assert.ok(stale.warnings.length > 0);
const identityMismatch = await lookup(cfg, releases, {packageName:'ghcr.io/other/image'});
assert.equal(identityMismatch.updates.length, 0);
const nonrootCfg = await config('gcr.io/distroless/static-debian12', 'nonroot');
assert.equal(nonrootCfg.versioning,'regex:^(?<major>0)?nonroot$');
const nonroot = await lookup(nonrootCfg, [{version:'nonroot',digest:digest('d'),releaseTimestamp:old}]);
assert.ok(nonroot.updates.some(u => u.updateType === 'digest' && u.newValue === 'nonroot' && u.newDigest === digest('d') && !u.pendingChecks));
const youngNonroot = await lookup(nonrootCfg, [{version:'nonroot',digest:digest('d'),releaseTimestamp:new Date().toISOString()}]);
assert.ok(youngNonroot.updates.some(u => u.updateType === 'digest' && u.pendingChecks));
const exempt = await config('ghcr.io/powerhome/example','1.0.0');
assert.equal(exempt.datasource,'docker');
for (const extra of [
  {registryUrls:['https://mirror.example']},
  {defaultRegistryUrls:['https://mirror.example']},
  {additionalRegistryUrls:['https://mirror.example']},
]) {
  assert.equal((await config('ghcr.io/astral-sh/uv','0.9.2',extra)).datasource,'docker');
}
assert.equal((await config('ghcr.io/astral-sh/uv','0.9.2',{registryUrls:['https://ghcr.io/']})).datasource,'custom.nip-publication');
console.log('Container extraction, digest and version lookup, age gating, stale/mismatched evidence, nonroot alias and first-party scope checks passed.');
