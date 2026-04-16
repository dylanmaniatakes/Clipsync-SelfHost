package com.bunty.clipsync

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp

@Composable
fun ServerConfigScreen(
    onBack: () -> Unit = {},
    onContinue: () -> Unit = {}
) {
    val context = LocalContext.current

    var baseUrl by remember { mutableStateOf(DeviceManager.getServerBaseUrl(context)) }
    var apiKey by remember { mutableStateOf(DeviceManager.getServerApiKey(context)) }
    var isTesting by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var successMessage by remember { mutableStateOf<String?>(null) }

    fun saveAndContinue() {
        errorMessage = null
        successMessage = null

        if (baseUrl.isBlank() || apiKey.isBlank()) {
            errorMessage = "Enter both the server URL and API key."
            return
        }

        isTesting = true
        FirestoreManager.validateServerConfiguration(
            baseUrl = baseUrl,
            apiKey = apiKey,
            onSuccess = {
                DeviceManager.saveServerConfiguration(context, baseUrl, apiKey)
                successMessage = "Connected to your self-hosted server."
                isTesting = false
                onContinue()
            },
            onFailure = { error ->
                errorMessage = error.message ?: "Unable to reach the server."
                isTesting = false
            }
        )
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "Direct Link",
            style = MaterialTheme.typography.headlineMedium,
            color = MaterialTheme.colorScheme.onBackground
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = "Direct link is the default setup. Start direct link on the Mac, then scan its QR code here.",
            style = MaterialTheme.typography.bodyMedium
        )

        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = "If you prefer a separate self-hosted server, you can still enter its URL and API key below.",
            style = MaterialTheme.typography.bodySmall
        )

        Spacer(modifier = Modifier.height(24.dp))

        Button(
            onClick = onContinue,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Scan Direct Link QR")
        }

        Spacer(modifier = Modifier.height(24.dp))

        Text(
            text = "Optional: Self-Hosted Server",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onBackground
        )

        Spacer(modifier = Modifier.height(12.dp))

        OutlinedTextField(
            value = baseUrl,
            onValueChange = { baseUrl = it },
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Server URL") },
            placeholder = { Text("http://192.168.1.10:8787") },
            singleLine = true
        )

        Spacer(modifier = Modifier.height(16.dp))

        OutlinedTextField(
            value = apiKey,
            onValueChange = { apiKey = it },
            modifier = Modifier.fillMaxWidth(),
            label = { Text("API Key") },
            visualTransformation = PasswordVisualTransformation(),
            singleLine = true
        )

        Spacer(modifier = Modifier.height(16.dp))

        if (!errorMessage.isNullOrBlank()) {
            Text(
                text = errorMessage!!,
                color = MaterialTheme.colorScheme.error
            )
            Spacer(modifier = Modifier.height(12.dp))
        }

        if (!successMessage.isNullOrBlank()) {
            Text(
                text = successMessage!!,
                color = MaterialTheme.colorScheme.primary
            )
            Spacer(modifier = Modifier.height(12.dp))
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            TextButton(onClick = onBack) {
                Text("Back")
            }

            Button(
                onClick = ::saveAndContinue,
                enabled = !isTesting
            ) {
                Text(if (isTesting) "Connecting..." else "Save & Scan QR")
            }
        }

        Spacer(modifier = Modifier.height(12.dp))
    }
}
