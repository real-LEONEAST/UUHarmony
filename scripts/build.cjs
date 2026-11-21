'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const [command = 'all', flag] = process.argv.slice(2);
if (!['native', 'hap', 'all', 'release'].includes(command) || (flag && flag !== '--offline')) {
  throw new Error('Usage: node scripts/build.cjs [all|native|hap|release] [--offline]');
}
const release = command === 'release';
const buildMode = release ? 'release' : 'debug';
const profile = path.join(root, 'build-profile.json5');
const profileTemplate = path.join(root, 'build-profile.example.json5');
if (release && fs.existsSync(profile) && !fs.readFileSync(profile).equals(fs.readFileSync(profileTemplate))) {
  throw new Error('Build the unsigned release in a clean checkout with build-profile.example.json5. The local profile was preserved.');
}

const studioPath = process.env.DEVECO_HOME;
if (!studioPath) {
  throw new Error('Set DEVECO_HOME to your DevEco Studio installation directory.');
}
const studio = path.resolve(studioPath);
const sdkHome = path.join(studio, 'sdk');
const sdk = path.join(sdkHome, 'default', 'openharmony');
const native = path.join(sdk, 'native');
const llvm = path.join(native, 'llvm', 'bin');
const tools = path.join(studio, 'tools');
const cmakeTools = path.join(native, 'build-tools', 'cmake', 'bin');
const exe = process.platform === 'win32' ? '.exe' : '';
const cargo = process.env.CARGO || 'cargo';
const node = path.join(tools, 'node', 'node' + exe);
const target = 'aarch64-unknown-linux-ohos';
const targetEnv = target.replace(/-/g, '_');
const buildDir = path.join(root, '.build');
const outputLibs = path.join(root, 'entry', 'libs', 'arm64-v8a');
const compiler = path.join(llvm, 'clang' + exe);
const sysroot = path.join(native, 'sysroot');

function buildPathMappings() {
  const home = os.homedir();
  const locations = [
    [studio, '/deveco'],
    [os.tmpdir(), '/tmp'],
    [home, '/build-home'],
    [process.env.CARGO_HOME || path.join(home, '.cargo'), '/cargo'],
    [root, '/src/uuharmony'],
  ];
  return locations.flatMap(([directory, replacement]) => {
    const absolute = path.resolve(directory);
    const prefixes = [absolute, absolute.replaceAll('\\', '/')];
    if (process.platform === 'win32') prefixes.push(path.toNamespacedPath(absolute));
    return [...new Set(prefixes)].map(prefix => `${prefix}=${replacement}`);
  });
}

const pathMappings = release ? buildPathMappings() : [];
const clangFlags = pathMappings.map(mapping => `-ffile-prefix-map=${mapping}`);
const quoteFlag = value => '"' + value.replaceAll('\\', '\\\\').replaceAll('"', '\\"') + '"';
const cFlags = ['--target=aarch64-linux-ohos', quoteFlag('--sysroot=' + sysroot), '-fPIC', ...clangFlags.map(quoteFlag)].join(' ');

const env = {
  ...process.env,
  DEVECO_PATH: studio,
  DEVECO_SDK_HOME: sdkHome,
  HVIGOR_USER_HOME: process.env.HVIGOR_USER_HOME || path.join(buildDir, 'hvigor'),
  PATH: [path.join(studio, 'jbr', 'bin'), path.join(tools, 'node'), process.env.PATH || ''].join(path.delimiter),
  CC_SHELL_ESCAPED_FLAGS: '1',
  ['CC_' + targetEnv]: compiler,
  ['CXX_' + targetEnv]: path.join(llvm, 'clang++' + exe),
  ['AR_' + targetEnv]: path.join(llvm, 'llvm-ar' + exe),
  ['CFLAGS_' + targetEnv]: cFlags,
  ['CXXFLAGS_' + targetEnv]: cFlags,
  CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER: compiler,
  CARGO_ENCODED_RUSTFLAGS: [
    '-Clink-arg=--target=aarch64-linux-ohos', '-Clink-arg=--sysroot=' + sysroot,
    ...pathMappings.map(mapping => `--remap-path-prefix=${mapping}`),
  ].join('\u001f'),
};

function run(executable, args, cwd = root) {
  const result = spawnSync(executable, args, { cwd, env, stdio: 'inherit', windowsHide: true });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(path.basename(executable) + ' exited with status ' + result.status);
  }
}

const libraryNames = ['s3c', 'uuhost', 'uufiles', 'uumic'];
if (command !== 'hap') {
  const buildArgs = ['build', '--locked', '--lib', '--release', '--target', target, '-j', '2'];
  if (flag === '--offline') buildArgs.push('--offline');
  run(cargo, buildArgs, path.join(root, 'host-rust'));
  run(cargo, [...buildArgs, '--features', 'rtp-diagnostics'], path.join(root, 'rust'));

  const cmake = path.join(cmakeTools, 'cmake' + exe);
  const nativeBuild = path.join(buildDir, release ? 'native-release' : 'native');
  const cmakeFlags = clangFlags.map(quoteFlag).join(' ');
  run(cmake, [
    '-S', path.join(root, 'entry', 'src', 'main', 'cpp'), '-B', nativeBuild, '-G', 'Ninja',
    '-DCMAKE_TOOLCHAIN_FILE=' + path.join(native, 'build', 'cmake', 'ohos.toolchain.cmake'),
    '-DCMAKE_MAKE_PROGRAM=' + path.join(cmakeTools, 'ninja' + exe),
    '-DOHOS_ARCH=arm64-v8a', '-DOHOS_PLATFORM=OHOS', '-DOHOS_STL=c++_shared',
    '-DCMAKE_BUILD_TYPE=' + (release ? 'Release' : 'Debug'),
    ...(release ? ['-DCMAKE_C_FLAGS=' + cmakeFlags, '-DCMAKE_CXX_FLAGS=' + cmakeFlags] : []),
  ]);
  run(cmake, ['--build', nativeBuild, '--target', ...libraryNames, '--parallel', '2']);
  fs.mkdirSync(outputLibs, { recursive: true });
  for (const name of libraryNames) {
    const file = 'lib' + name + '.so';
    run(path.join(llvm, 'llvm-strip' + exe), ['--strip-unneeded', '-o',
      path.join(outputLibs, file), path.join(nativeBuild, file)]);
  }
  fs.copyFileSync(path.join(native, 'llvm', 'lib', 'aarch64-linux-ohos', 'libc++_shared.so'),
    path.join(outputLibs, 'libc++_shared.so'));
}

if (command !== 'native') {
  for (const file of [...libraryNames.map(name => 'lib' + name + '.so'), 'libc++_shared.so']) {
    if (!fs.existsSync(path.join(outputLibs, file))) {
      throw new Error('Native libraries are missing. Build them with node scripts/build.cjs native first.');
    }
  }
  if (!fs.existsSync(profile)) {
    fs.copyFileSync(profileTemplate, profile, fs.constants.COPYFILE_EXCL);
  }
  run(node, [path.join(tools, 'ohpm', 'bin', 'pm-cli.js'), 'install', '--all', '--no-save']);
  const hvigor = path.join(tools, 'hvigor', 'bin', 'hvigorw.js');
  const args = ['-p', 'product=default', '-p', 'buildMode=' + buildMode, '--analyze=normal'];
  run(node, [hvigor, '--sync', ...args]);
  run(node, [hvigor, 'assembleApp', ...args]);
  const hapDir = path.join(root, 'entry', 'build', 'default', 'outputs', 'default');
  if (release) {
    const appDir = path.join(root, 'build', 'outputs', 'default');
    const packInfo = JSON.parse(fs.readFileSync(path.join(appDir, 'pack.info'), 'utf8'));
    const version = packInfo.summary.app.version.name;
    if (!/^[0-9][0-9A-Za-z.+-]{0,63}$/.test(version)) {
      throw new Error('The package version cannot be used in a release filename.');
    }
    const inputHap = path.join(hapDir, 'entry-default-unsigned.hap');
    const appFiles = fs.readdirSync(appDir).filter(file => file.endsWith('-default-unsigned.app'));
    if (appFiles.length !== 1 || !fs.statSync(inputHap).size) {
      throw new Error('Expected one unsigned HAP and one unsigned APP.');
    }
    const inputApp = path.join(appDir, appFiles[0]);
    if (!fs.statSync(inputApp).size) throw new Error('The unsigned APP is empty.');

    const destination = path.join(buildDir, 'release');
    fs.mkdirSync(destination, { recursive: true });
    const stem = 'UUHarmony-v' + version;
    fs.copyFileSync(inputHap, path.join(destination, stem + '.hap'));
    fs.copyFileSync(inputApp, path.join(destination, stem + '.app'));
    console.log('Unsigned release outputs: ' + destination);
  } else {
    console.log('HAP output: ' + hapDir);
  }
}
