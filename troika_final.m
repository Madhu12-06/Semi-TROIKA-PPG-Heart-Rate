%% --- STEP 0: Load Data (Robust Version) ---
clear; clc; close all;
disp('Loading data...');

% We skip the text headers and start reading from the actual numbers.
% If your CSV has exactly 5 text lines before the data, we skip 5 lines.
opts = detectImportOptions('IEEEPPG_TRAIN.csv');
opts.DataLines = [6, 305]; % Skip 5 header lines, read 300 rows
opts.VariableNamingRule = 'preserve'; % Keep original names

T = readtable('IEEEPPG_TRAIN.csv', opts);

% Extract data directly by column index (safer than using names)
y = T{:, 2};           % Column 2 is HR
ppg1 = T{:, 3:1002};   % Columns 3 to 1002
ppg2 = T{:, 1003:2002};% Columns 1003 to 2002
accx = T{:, 2003:3002};
accy = T{:, 3003:4002};
accz = T{:, 4003:5002};

% Combine into 3D matrix
X = zeros(size(ppg1, 1), 1000, 5);
X(:,:,1) = ppg1; X(:,:,2) = ppg2; 
X(:,:,3) = accx; X(:,:,4) = accy; X(:,:,5) = accz;

fs = 125;
nRows = size(X, 1);
nSamples = size(X, 2);

%% --- CRITERION 1: ACC-Guided Denoising ---
disp('Running Criterion 1: ACC-Guided Denoising...');

bpFilt = designfilt('bandpassiir', 'FilterOrder', 4, ...
    'PassbandFrequency1', 0.5, 'PassbandFrequency2', 4.0, ...
    'SampleRate', fs);

denoisedPPG = zeros(nRows, nSamples);
cleanACC = zeros(nRows, nSamples);

for k = 1:nRows
    % 1. PPG Signal (average of 2 channels)
    ppg = mean([squeeze(X(k,:,1)); squeeze(X(k,:,2))], 1);

    % 2. Apply Bandpass Filter ONLY. (Do NOT use NLMS as it destroys the signal)
    denoisedPPG(k,:) = filtfilt(bpFilt, ppg);

    % 3. ACC Reference: Pick the axis with the HIGHEST variance (the dominant motion)
    accAll = [squeeze(X(k,:,3)); squeeze(X(k,:,4)); squeeze(X(k,:,5))];
    [~, maxIdx] = max(var(accAll, 0, 2));
    accBest = accAll(maxIdx, :);
    cleanACC(k,:) = filtfilt(bpFilt, accBest);
end

%% --- CRITERION 2: High-Res Spectrum (CZT) ---
disp('Running Criterion 2: CZT Spectrum...');

fLow  = 0.7;  % 42 BPM
fHigh = 4.0;  % 240 BPM
M     = 1024; % High resolution bins

% Setup CZT parameters
w = exp(-1j*2*pi*(fHigh-fLow)/(M*fs));
a = exp(1j*2*pi*fLow/fs);
freqAxisHz = linspace(fLow, fHigh, M);

specAll = zeros(nRows, M);
accSpecAll = zeros(nRows, M);

for k = 1:nRows
    % CZT for PPG
    S = czt(denoisedPPG(k,:), M, w, a);
    specAll(k,:) = abs(S);
    
    % CZT for ACC (for verification in Criterion 3)
    A = czt(cleanACC(k,:), M, w, a);
    accSpecAll(k,:) = abs(A);
end

%% --- CRITERION 3: Spectral Peak Tracking with Verification ---
disp('Running Criterion 3: Peak Tracking...');

estimatedBPM = zeros(nRows,1);
prevHR = y(1); 

for k = 1:nRows
    spec = specAll(k,:);
    aSpec = accSpecAll(k,:);

    % 1. Find the top 10 peaks in the PPG spectrum
    [pks, locs] = findpeaks(spec, 'SortStr','descend', 'NPeaks', 10);

    bestScore = -inf;
    bestBPM = prevHR;

    for i = 1:numel(locs)
        bpmCandidate = freqAxisHz(locs(i)) * 60;

        % --- SCORE 1: Magnitude ---
        magScore = pks(i) / max(pks);

        % --- SCORE 2: Continuity (Tighter tolerance) ---
        contScore = exp(-((bpmCandidate - prevHR)^2) / (2 * 12^2));

        % --- SCORE 3: ACC Verification (Proportional Penalty) ---
        idxNear = max(1, locs(i)-15) : min(M, locs(i)+15);
        accRatio = max(aSpec(idxNear)) / max(aSpec);
        accPenalty = 1 / (1 + 5 * accRatio); % Soft penalty, no hard zero

        % --- SCORE 4: SUB-HARMONIC BOOST (The Magic Fix) ---
        % If the candidate has a strong peak at exactly half its frequency,
        % it is likely a harmonic. We boost the score of the fundamental.
        halfHz = freqAxisHz(locs(i)) / 2;
        [~, halfIdx] = min(abs(freqAxisHz - halfHz));
        halfMag = spec(halfIdx) / max(spec);

        harmonicBoost = 1 + (halfMag * 2); % If half peak is 50%, boost by 2x

        % Calculate Final Score
        totalScore = magScore * contScore * accPenalty * harmonicBoost;

        if totalScore > bestScore
            bestScore = totalScore;
            bestBPM = bpmCandidate;
        end
    end

    % --- FINAL SAFETY CHECK ---
    % If the chosen BPM is more than 20 BPM away from the last one,
    % and the previous HR is stable, trust the previous HR more.
    if abs(bestBPM - prevHR) > 20 && k > 5
        % Check if there is a peak closer to prevHR
        [~, closeIdx] = min(abs(freqAxisHz - (prevHR/60)));
        if spec(closeIdx) > 0.2 * max(spec)
            bestBPM = prevHR; % Stick to the previous HR
        end
    end

    estimatedBPM(k) = bestBPM;
    prevHR = bestBPM;
end

% Apply a median filter to smooth out any remaining outliers
estimatedBPM = medfilt1(estimatedBPM, 5);

%% --- STEP 4: Validation and Plots ---
err = estimatedBPM - y;
mae = mean(abs(err), 'omitnan');
rmse = sqrt(mean(err.^2, 'omitnan'));

fprintf('\n=== Final Results ===\n');
fprintf('MAE  = %.2f BPM\n', mae);
fprintf('RMSE = %.2f BPM\n', rmse);

% Plot 1: Tracking line
figure('Name', 'Reference vs Estimated HR');
plot(y, 'b-', 'LineWidth', 2); hold on;
plot(estimatedBPM, 'r--', 'LineWidth', 1.5);
legend('Reference HR', 'Estimated HR');
xlabel('Window Index (2 seconds per window)'); ylabel('Heart Rate (BPM)');
title(sprintf('HR Tracking (MAE = %.2f BPM)', mae));
grid on;

% Plot 2: Scatter
figure('Name', 'Scatter Plot');
scatter(y, estimatedBPM, 20, 'filled'); hold on;
plot([40 220], [40 220], 'r--', 'LineWidth', 2);
xlabel('Reference HR (BPM)'); ylabel('Predicted HR (BPM)');
title('Predicted HR vs Reference HR');
grid on;

% Plot 3: CZT Spectrum Example
k_show = 50; 
figure('Name', 'CZT Spectrum vs ACC Spectrum');
subplot(2,1,1);
plot(freqAxisHz * 60, specAll(k_show,:), 'b-', 'LineWidth', 1.5);
title(sprintf('PPG CZT Spectrum (Window %d)', k_show));
xlabel('Frequency (BPM)'); ylabel('Magnitude'); grid on;

subplot(2,1,2);
plot(freqAxisHz * 60, accSpecAll(k_show,:), 'r-', 'LineWidth', 1.5);
title('ACC CZT Spectrum');
xlabel('Frequency (BPM)'); ylabel('Magnitude'); grid on;

% Plot 4: Time Domain Denoising (Criterion 1)
k_plot = 50; % Look at window 50
t = (1:1000) / fs; % Time axis in seconds

figure('Name', 'Criterion 1: Denoising');
subplot(3,1,1);
raw_ppg = mean([squeeze(X(k_plot,:,1)); squeeze(X(k_plot,:,2))], 1);
plot(t, raw_ppg, 'k'); title(sprintf('Raw PPG (Window %d)', k_plot)); ylabel('Amplitude'); grid on;

subplot(3,1,2);
plot(t, denoisedPPG(k_plot,:), 'b', 'LineWidth', 1.5); 
title('Filtered PPG (Ready for CZT)'); ylabel('Amplitude'); grid on;

subplot(3,1,3);
plot(t, cleanACC(k_plot,:), 'r'); 
title('Dominant ACC Axis (Motion Reference)'); xlabel('Time (seconds)'); ylabel('Acceleration'); grid on;

% Plot 5: Error Histogram
figure('Name', 'Error Distribution');
histogram(err, 30, 'FaceColor', '#0072BD');
title(sprintf('Heart Rate Estimation Error (MAE = %.2f BPM)', mae));
xlabel('Error (BPM)'); ylabel('Number of Windows');
grid on;