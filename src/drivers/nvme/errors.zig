pub const NvmeError = error{ InvalidCommand, InvalidCommandSequence, AdminCommandNoData, AdminCommandFailed, MsiXMisconfigured, InvalidLBA, InvalidNsid, IONvmReadFailed, UnsupportedControllerVersion, ControllerDoesNotSupportNvmCommandSet, ControllerDoesNotSupportAdminCommandSet, ControllerDoesNotSupportHostPageSize, FailedToExecuteIdentifyCommand, NoValidIoCommandSetCombination, FailedToExecuteSetFeaturesCommand };
